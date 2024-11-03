import Foundation
import Network
import Combine
import AppKit
import SwiftUI


private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var completionHandler: (URL?, URLResponse?, Error?) -> Void
    var progressHandler: ((Int64, Int64, Int64) -> Void)?
    var destinationDirectory: URL
    var fileName: String
    
    init(destinationDirectory: URL,
         fileName: String,
         completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void,
         progressHandler: ((Int64, Int64, Int64) -> Void)? = nil) {
        self.destinationDirectory = destinationDirectory
        self.fileName = fileName
        self.completionHandler = completionHandler
        self.progressHandler = progressHandler
        super.init()
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            }
            let destinationURL = destinationDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            Thread.sleep(forTimeInterval: 0.5)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let fileSize = try FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64 ?? 0
                completionHandler(destinationURL, downloadTask.response, nil)
            } else {
                completionHandler(nil, downloadTask.response, NetworkError.fileSystemError("文件移动后不存在", nil))
            }
        } catch {
            print("File operation error in delegate: \(error.localizedDescription)")
            completionHandler(nil, downloadTask.response, error)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        switch (error as NSError).code {
        case NSURLErrorCancelled:
            return
        case NSURLErrorTimedOut:
            completionHandler(nil, task.response, NetworkError.downloadError("下载超时", error))
        case NSURLErrorNotConnectedToInternet:
            completionHandler(nil, task.response, NetworkError.noConnection)
        default:
            completionHandler(nil, task.response, error)
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, 
                   didWriteData bytesWritten: Int64, 
                   totalBytesWritten: Int64, 
                   totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        guard bytesWritten > 0 else { return }
        
        progressHandler?(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
    }
    func cleanup() {
        completionHandler = { _, _, _ in }
        progressHandler = nil
    }
}

@MainActor
class NetworkManager: ObservableObject {
    typealias ProgressUpdate = (bytesWritten: Int64, totalWritten: Int64, expectedToWrite: Int64)
    @Published var isConnected = false
    @Published var saps: [String: Sap] = [:]
    @Published var cdn: String = ""
    @Published var allowedPlatform = ["macuniversal", "macarm64", "osx10-64", "osx10"]
    @Published var sapCodes: [SapCodes] = []
    @Published var loadingState: LoadingState = .idle
    @Published var downloadTasks: [NewDownloadTask] = []
    @Published var installationState: InstallationState = .idle
    private let cancelTracker = CancelTracker()
    internal var downloadUtils: DownloadUtils!
    internal var progressObservers: [UUID: NSKeyValueObservation] = [:]
    internal var activeDownloadTaskId: UUID?
    internal var monitor = NWPathMonitor()
    internal var isFetchingProducts = false
    private let installManager = InstallManager()
    
    enum InstallationState {
        case idle
        case installing(progress: Double, status: String)
        case completed
        case failed(Error)
    }

    init() {
        self.downloadUtils = DownloadUtils(networkManager: self, cancelTracker: cancelTracker)
        setupNetworkMonitoring()
    }

    func fetchProducts() async {
        await fetchProductsWithRetry()
    }
    func startDownload(sap: Sap, selectedVersion: String, language: String, destinationURL: URL) async throws {
        guard let productInfo = self.saps[sap.sapCode]?.versions[selectedVersion] else {
            throw NetworkError.invalidData("无法获取产品信息")
        }
        
        // 1. 创建下载任务
        let task = NewDownloadTask(
            sapCode: sap.sapCode,
            version: selectedVersion,
            language: language,
            displayName: sap.displayName,
            directory: destinationURL,
            productsToDownload: [],
            createAt: Date(),
            totalStatus: .preparing(DownloadStatus.PrepareInfo(
                message: "正在准备下载...",
                timestamp: Date(),
                stage: .initializing
            )),
            totalProgress: 0,
            totalDownloadedSize: 0,
            totalSize: 0,
            totalSpeed: 0
        )
        
        downloadTasks.append(task)
        
        do {
            // 2. 创建基础目录结构
            // print("Creating installer app structure at: \(destinationURL.path)")
            try downloadUtils.createInstallerApp(
                for: task.sapCode,
                version: task.version,
                language: task.language,
                at: task.directory
            )
            
            // 3. 收集所有需要下载的产品
            var productsToDownload: [ProductsToDownload] = []
            
            // 添加主产品
            productsToDownload.append(ProductsToDownload(
                sapCode: sap.sapCode,
                version: selectedVersion,
                buildGuid: productInfo.buildGuid
            ))
            
            // 添加依赖
            for dependency in productInfo.dependencies {
                if let dependencyVersions = saps[dependency.sapCode]?.versions {
                    let sortedVersions = dependencyVersions.sorted { first, second in
                        first.value.productVersion.compare(second.value.productVersion, options: .numeric) == .orderedDescending
                    }
                    
                    var buildGuid = ""
                    for (_, versionInfo) in sortedVersions where versionInfo.baseVersion == dependency.version {
                        if allowedPlatform.contains(versionInfo.apPlatform) {
                            buildGuid = versionInfo.buildGuid
                            break
                        }
                    }
                    
                    if !buildGuid.isEmpty {
                        productsToDownload.append(ProductsToDownload(
                            sapCode: dependency.sapCode,
                            version: dependency.version,
                            buildGuid: buildGuid
                        ))
                    }
                }
            }
            
            // 4. 为每个产品创建目录并下载 application.json
            for product in productsToDownload {
                await MainActor.run {
                    task.setStatus(.preparing(DownloadStatus.PrepareInfo(
                        message: "正在处理 \(product.sapCode) 的产品信息...",
                        timestamp: Date(),
                        stage: .fetchingInfo
                    )))
                    objectWillChange.send()
                }
                
                // 创建产品目录
                let productDir = task.directory.appendingPathComponent("Contents/Resources/products/\(product.sapCode)")
                if !FileManager.default.fileExists(atPath: productDir.path) {
                    try FileManager.default.createDirectory(at: productDir, withIntermediateDirectories: true)
                }
                
                // 下载 application.json
                await MainActor.run {
                    task.setStatus(.preparing(DownloadStatus.PrepareInfo(
                        message: "正在下载 \(product.sapCode) 的产品信息...",
                        timestamp: Date(),
                        stage: .fetchingInfo
                    )))
                    objectWillChange.send()
                }
                
                let jsonString = try await getApplicationInfo(buildGuid: product.buildGuid)
                
                // 保存 application.json
                let jsonURL = productDir.appendingPathComponent("application.json")
                print("Saving application.json to: \(jsonURL.path)")
                try jsonString.write(to: jsonURL, atomically: true, encoding: .utf8)
                
                // 解析包信息
                guard let jsonData = jsonString.data(using: .utf8),
                      let appInfo = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let packages = appInfo["Packages"] as? [String: Any],
                      let packageArray = packages["Package"] as? [[String: Any]] else {
                    throw NetworkError.invalidData("无法解析产品信息")
                }
                
                // 解析每个包的信息
                for package in packageArray {
                    // 获取包名，优先使用 fullPackageName，如果为空则使用 PackageName
                    let fullPackageName: String
                    if let name = package["fullPackageName"] as? String, !name.isEmpty {
                        fullPackageName = name
                    } else if let name = package["PackageName"] as? String, !name.isEmpty {
                        fullPackageName = name
                        // print("Using PackageName instead of fullPackageName for package in \(product.sapCode): \(name)")
                    } else {
                        // print("Warning: Skipping package with empty name in \(product.sapCode)")
                        continue
                    }
                    
                    let packageType = package["Type"] as? String ?? "non-core"
                    
                    // 解析下载大小
                    let downloadSize: Int64
                    if let sizeNumber = package["DownloadSize"] as? NSNumber {
                        downloadSize = sizeNumber.int64Value
                    } else if let sizeString = package["DownloadSize"] as? String,
                              let parsedSize = Int64(sizeString) {
                        downloadSize = parsedSize
                    } else if let sizeInt = package["DownloadSize"] as? Int {
                        downloadSize = Int64(sizeInt)
                    } else {
                        // print("Warning: Invalid download size for package: \(fullPackageName) in \(product.sapCode)")
                        continue // 跳过无效的包
                    }
                    
                    guard let downloadURL = package["Path"] as? String,
                          !downloadURL.isEmpty else {
                        print("Warning: Missing download URL for package: \(fullPackageName) in \(product.sapCode)")
                        continue
                    }
                    
                    // print("Valid package found - Name: \(fullPackageName), Type: \(packageType), Size: \(downloadSize), URL: \(downloadURL)")

                    let newPackage = Package(
                        type: packageType,
                        fullPackageName: fullPackageName,
                        downloadSize: downloadSize,
                        downloadURL: downloadURL
                    )
                    product.packages.append(newPackage)
                }
            }
            
            // 5. 更新任务信息
            task.productsToDownload = productsToDownload
            task.totalSize = productsToDownload.reduce(0) { productSum, product in
                productSum + product.packages.reduce(0) { packageSum, pkg in
                    packageSum + (pkg.downloadSize > 0 ? pkg.downloadSize : 0)
                }
            }
            
            print("Total download size: \(task.totalSize) bytes")
            print("Starting download process...")
            
            // 6. 开始下载过程
            await downloadUtils.startDownloadProcess(task: task)
            
        } catch {
            await MainActor.run {
                task.setStatus(.failed(DownloadStatus.FailureInfo(
                    message: error.localizedDescription,
                    error: error,
                    timestamp: Date(),
                    recoverable: true
                )))
                objectWillChange.send()
            }
            throw error
        }
    }

    private func validateAndStartDownload(task: NewDownloadTask) async throws {
        // 创建安装程序目录结构
        try downloadUtils.createInstallerApp(
            for: task.sapCode,
            version: task.version,
            language: task.language,
            at: task.directory
        )
        await startDownloadProcess(task: task)
    }
    
    internal func startDownloadProcess(task: NewDownloadTask) async {
        // 1. 更新任务状态为准备中
        task.totalStatus = .preparing(DownloadStatus.PrepareInfo(
            message: "正在准备下载...",
            timestamp: Date(),
            stage: .initializing
        ))
        
        // 2. 遍历所有产品的包
        for product in task.productsToDownload {
            let sapCode = product.sapCode
            let version = product.version
            
            // 3. 创建产品目录
            let productDir = task.directory.appendingPathComponent("Contents/Resources/products/\(sapCode)")
            try? FileManager.default.createDirectory(at: productDir, withIntermediateDirectories: true)
            
            // 4. 开始下载包
            for package in product.packages {
                // 更新当前包信息
                task.currentPackage = package
                
                // 构建下载 URL
                let downloadURL = cdn + package.downloadURL
                guard let url = URL(string: downloadURL) else { continue }
                
                var request = URLRequest(url: url)
                NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                
                let delegate = DownloadDelegate(
                    destinationDirectory: task.directory.appendingPathComponent("Contents/Resources/products/\(sapCode)"),
                    fileName: package.fullPackageName,
                    completionHandler: { [weak self] localURL, response, error in
                        if let error = error {
                            Task {
                                await self?.handleError(task.id, error)
                            }
                            return
                        }
                        
                        // 更新包状态
                        package.downloaded = true
                        package.progress = 1.0
                        package.status = .completed
                        
                        // 更新总进度
                        let totalDownloaded = task.productsToDownload.reduce(0) { sum, product in
                            sum + product.packages.reduce(0) { sum, pkg in
                                sum + (pkg.downloaded ? pkg.downloadSize : 0)
                            }
                        }
                        let totalSize = task.productsToDownload.reduce(0) { sum, product in
                            sum + product.packages.reduce(0) { sum, pkg in pkg.downloadSize }
                        }
                        task.totalProgress = Double(totalDownloaded) / Double(totalSize)
                    },
                    progressHandler: { bytesWritten, totalBytesWritten, totalBytesExpectedToWrite in
                        package.downloadedSize = totalBytesWritten
                        package.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                        package.speed = Double(bytesWritten)
                        package.status = .downloading
                        
                        task.totalDownloadedSize = totalBytesWritten
                        task.totalSize = totalBytesExpectedToWrite
                        task.totalSpeed = Double(bytesWritten)
                    }
                )
                
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let downloadTask = session.downloadTask(with: request)
                downloadTask.resume()
                
                // 等待下载完成
                await withCheckedContinuation { continuation in
                    delegate.completionHandler = { _, _, _ in
                        continuation.resume()
                    }
                }
            }
        }
        
        // 5. 所有包下载完成后，生成 driver.xml
        let driverXml = downloadUtils.generateDriverXML(
            sapCode: task.sapCode,
            version: task.version,
            language: task.language,
            productInfo: (self.saps[task.sapCode]?.versions[task.version])!,
            displayName: task.displayName
        )
        
        try? driverXml.write(
            to: task.directory.appendingPathComponent("Contents/Resources/products/driver.xml"),
            atomically: true,
            encoding: .utf8
        )
        
        // 6. 更新任务状态为完成
        task.totalStatus = .completed(DownloadStatus.CompletionInfo(
            timestamp: Date(),
            totalTime: Date().timeIntervalSince(task.createAt),
            totalSize: task.totalSize
        ))
    }

   private func performDownload(task: NewDownloadTask) async throws {
       if task.sapCode == "APRO" {
           // APRO 的特殊处理
           // 暂时移除 APRO 的处理，或者实现新的处理逻辑
           return
       }

       try downloadUtils.createInstallerApp(
           for: task.sapCode,
           version: task.version,
           language: task.language,
           at: task.directory
       )

       try await downloadUtils.signApp(at: task.directory)

       let productsDir = task.directory.appendingPathComponent("Contents/Resources/products")
       try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)

       print("\nPreparing...\n")
       for product in task.productsToDownload {
           let sapCode = product.sapCode
           let version = product.version

           print("[\(sapCode)_\(version)] Downloading application.json")
           let jsonString = try await getApplicationInfo(buildGuid: product.buildGuid)

           print("[\(sapCode)_\(version)] Creating folder for product")
           let productDir = productsDir.appendingPathComponent(sapCode)
           try FileManager.default.createDirectory(at: productDir, withIntermediateDirectories: true)

           print("[\(sapCode)_\(version)] Saving application.json")
           try jsonString.write(to: productDir.appendingPathComponent("application.json"),
                              atomically: true,
                              encoding: .utf8)
           
           // ... 其他处理逻辑 ...
       }

       print("\nGenerating driver.xml")
       if let productInfo = self.saps[task.sapCode]?.versions[task.version] {
           let driverXml = downloadUtils.generateDriverXML(
               sapCode: task.sapCode,
               version: task.version,
               language: task.language,
               productInfo: productInfo,
               displayName: task.displayName
           )

           try driverXml.write(
               to: productsDir.appendingPathComponent("driver.xml"),
               atomically: true,
               encoding: .utf8
           )
       }

       await resumeDownload(taskId: task.id)
   }

   func pauseDownload(taskId: UUID) {
       Task {
           if let task = downloadTasks.first(where: { $0.id == taskId }) {
               await MainActor.run {
                   task.setStatus(.paused(DownloadStatus.PauseInfo(
                       reason: .userRequested,
                       timestamp: Date(),
                       resumable: true
                   )))
                   objectWillChange.send()
               }
               await cancelTracker.pause(taskId)
           }
       }
   }
    
   func resumeDownload(taskId: UUID) async {
       if let task = downloadTasks.first(where: { $0.id == taskId }) {
           await MainActor.run {
               task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                   fileName: task.currentPackage?.fullPackageName ?? "",
                   currentPackageIndex: 0,
                   totalPackages: task.productsToDownload.reduce(0) { $0 + $1.packages.count },
                   startTime: Date(),
                   estimatedTimeRemaining: nil
               )))
               objectWillChange.send()
           }
           
           // 重新开始下载过程
           await downloadUtils.startDownloadProcess(task: task)
       }
   }
   
   func cancelDownload(taskId: UUID, removeFiles: Bool = false) {
       Task {
           if let task = downloadTasks.first(where: { $0.id == taskId }) {
               await MainActor.run {
                   task.setStatus(.failed(DownloadStatus.FailureInfo(
                       message: "下载已取消",
                       error: NetworkError.downloadCancelled,
                       timestamp: Date(),
                       recoverable: false
                   )))
                   objectWillChange.send()
               }
               await cancelTracker.cancel(taskId)
               if removeFiles {
                   try? FileManager.default.removeItem(at: task.directory)
               }
           }
       }
   }
    
   func clearCompletedTasks() {
       Task {
           await clearCompletedDownloadTasks()
       }
   }

    private func setupNetworkMonitoring() {
        configureNetworkMonitor()
    }

   private func handleDownloadError(taskId: UUID, error: Error) async {
       guard let index = downloadTasks.firstIndex(where: { $0.id == taskId }) else { return }
       let task = downloadTasks[index]
       
       let (errorMessage, isRecoverable) = classifyError(error)
       
       if isRecoverable && task.retryCount < NetworkConstants.maxRetryAttempts {
           task.retryCount += 1
           let nextRetryDate = Date().addingTimeInterval(TimeInterval(NetworkConstants.retryDelay / 1_000_000_000))
           task.setStatus(.retrying(DownloadStatus.RetryInfo(
               attempt: task.retryCount,
               maxAttempts: NetworkConstants.maxRetryAttempts,
               reason: errorMessage,
               nextRetryDate: nextRetryDate
           )))
           
           Task {
               do {
                   try await Task.sleep(nanoseconds: NetworkConstants.retryDelay)
                   if await !cancelTracker.isCancelled(taskId) {
                       await downloadUtils.resumeDownloadTask(taskId: taskId)
                   }
               } catch {
                   print("Retry cancelled for task: \(taskId)")
               }
           }
       } else {
           task.setStatus(.failed(DownloadStatus.FailureInfo(
               message: errorMessage,
               error: error,
               timestamp: Date(),
               recoverable: isRecoverable
           )))
           
           progressObservers[taskId]?.invalidate()
           progressObservers.removeValue(forKey: taskId)
           
           if let currentPackage = task.currentPackage {
               let destinationDir = task.directory
                   .appendingPathComponent("Contents/Resources/products/\(task.sapCode)")
               let fileURL = destinationDir.appendingPathComponent(currentPackage.fullPackageName)
               try? FileManager.default.removeItem(at: fileURL)
           }
           
           updateDockBadge()
           objectWillChange.send()
       }
   }
   
   private func classifyError(_ error: Error) -> (message: String, recoverable: Bool) {
       switch error {
       case let networkError as NetworkError:
           switch networkError {
           case .noConnection:
               return ("网络连接已断开", true)
           case .timeout:
               return ("下载超时", true)
           case .serverUnreachable:
               return ("服务器无法访问", true)
           case .insufficientStorage:
               return ("存储空间不足", false)
           case .filePermissionDenied:
               return ("没有入权限", false)
           default:
               return (networkError.localizedDescription, false)
           }
       case let urlError as URLError:
           switch urlError.code {
           case .notConnectedToInternet:
               return ("网络连接已开", true)
           case .timedOut:
               return ("连接超时", true)
           case .cancelled:
               return ("下载已取消", false)
           default:
               return (urlError.localizedDescription, true)
           }
       default:
           return (error.localizedDescription, false)
       }
   }

   private func updateProgress(for taskId: UUID, progress: ProgressUpdate) {
       guard let index = downloadTasks.firstIndex(where: { $0.id == taskId }) else { return }
       let task = downloadTasks[index]
       
       // 找到当前正在下载的包
       guard let currentPackage = task.currentPackage else { return }
       
       let now = Date()
       let timeDiff = now.timeIntervalSince(currentPackage.lastUpdated)
       
       // 每秒更新一次进度
       if timeDiff >= NetworkConstants.progressUpdateInterval {
           Task { @MainActor in
               // 使用 Package 的 updateProgress 方法更新包进度
               currentPackage.updateProgress(
                   downloadedSize: progress.totalWritten,
                   speed: Double(progress.bytesWritten)
               )
               
               // 更新任务总进度
               let totalDownloaded = task.productsToDownload.reduce(Int64(0)) { sum, prod in
                   sum + prod.packages.reduce(Int64(0)) { sum, pkg in
                       if pkg.downloaded {
                           return sum + pkg.downloadSize
                       } else if pkg.id == currentPackage.id {
                           return sum + progress.totalWritten
                       }
                       return sum
                   }
               }
               
               task.totalDownloadedSize = totalDownloaded
               task.totalProgress = Double(totalDownloaded) / Double(task.totalSize)
               task.totalSpeed = currentPackage.speed
               
               // 更新包的记录
               currentPackage.lastRecordedSize = progress.totalWritten
               currentPackage.lastUpdated = now
               
               // 检查当前包是否下载完成
               if progress.totalWritten >= progress.expectedToWrite {
                   currentPackage.markAsCompleted()
               }
               
               // 触发 UI 更新
               task.objectWillChange.send()
               objectWillChange.send()
           }
       }
   }

   private func updateTaskStatus(_ taskId: UUID, _ status: DownloadStatus) async {
       await MainActor.run {
           if let index = downloadTasks.firstIndex(where: { $0.id == taskId }) {
               downloadTasks[index].setStatus(status)
               
               switch status {
               case .completed:
                   progressObservers[taskId]?.invalidate()
                   progressObservers.removeValue(forKey: taskId)
                   if activeDownloadTaskId == taskId {
                       activeDownloadTaskId = nil
                   }
                   
               case .failed:
                   progressObservers[taskId]?.invalidate()
                   progressObservers.removeValue(forKey: taskId)
                   if activeDownloadTaskId == taskId {
                       activeDownloadTaskId = nil
                   }
                   
               case .downloading:
                   activeDownloadTaskId = taskId
                   
               case .paused:
                   if activeDownloadTaskId == taskId {
                       activeDownloadTaskId = nil
                   }
                   
               default:
                   break
               }
               
               updateDockBadge()
               objectWillChange.send()
           }
       }
   }

    private func clampProgress(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    func retryFetchData() {
        Task {
            isFetchingProducts = false
            loadingState = .idle
            await fetchProducts()
        }
    }

    func getActiveTaskId() async -> UUID? {
        await MainActor.run { activeDownloadTaskId }
    }
    
   func setTaskStatus(_ taskId: UUID, _ status: DownloadStatus) async {
       await updateTaskStatus(taskId, status)
   }
   
   func getTasks() async -> [NewDownloadTask] {
       await MainActor.run { downloadTasks }
   }
   
   func handleError(_ taskId: UUID, _ error: Error) async {
       guard let index = downloadTasks.firstIndex(where: { $0.id == taskId }) else { return }
       let task = downloadTasks[index]
       
       let (errorMessage, isRecoverable) = classifyError(error)
       
       if isRecoverable && task.retryCount < NetworkConstants.maxRetryAttempts {
           task.retryCount += 1
           let nextRetryDate = Date().addingTimeInterval(TimeInterval(NetworkConstants.retryDelay / 1_000_000_000))
           task.setStatus(.retrying(DownloadStatus.RetryInfo(
               attempt: task.retryCount,
               maxAttempts: NetworkConstants.maxRetryAttempts,
               reason: errorMessage,
               nextRetryDate: nextRetryDate
           )))
           
           Task {
               do {
                   try await Task.sleep(nanoseconds: NetworkConstants.retryDelay)
                   if await !cancelTracker.isCancelled(taskId) {
                       await downloadUtils.resumeDownloadTask(taskId: taskId)
                   }
               } catch {
                   print("Retry cancelled for task: \(taskId)")
               }
           }
       } else {
           task.setStatus(.failed(DownloadStatus.FailureInfo(
               message: errorMessage,
               error: error,
               timestamp: Date(),
               recoverable: isRecoverable
           )))
           
           progressObservers[taskId]?.invalidate()
           progressObservers.removeValue(forKey: taskId)
           
           if let currentPackage = task.currentPackage {
               let destinationDir = task.directory
                   .appendingPathComponent("Contents/Resources/products/\(task.sapCode)")
               let fileURL = destinationDir.appendingPathComponent(currentPackage.fullPackageName)
               try? FileManager.default.removeItem(at: fileURL)
           }
           
           updateDockBadge()
           objectWillChange.send()
       }
   }
   func updateDownloadProgress(for taskId: UUID, progress: ProgressUpdate) {
       updateProgress(for: taskId, progress: progress)
   }

    var cdnUrl: String {
        get async {
            await MainActor.run { cdn }
        }
    }

   func removeTask(taskId: UUID, removeFiles: Bool = true) {
       Task {
           await cancelTracker.cancel(taskId)
           
           if let task = downloadTasks.first(where: { $0.id == taskId }) {
               if removeFiles {
                   do {
                       if FileManager.default.fileExists(atPath: task.directory.path) {
                           try FileManager.default.removeItem(at: task.directory)
                       }
                       
                       let productsPath = task.directory.appendingPathComponent("Contents/Resources/products/\(task.sapCode)")
                       if FileManager.default.fileExists(atPath: productsPath.path) {
                           try FileManager.default.removeItem(at: productsPath)
                       }
                   } catch {
                       print("Error removing files for task \(taskId): \(error.localizedDescription)")
                   }
               }
               
               await MainActor.run {
                   downloadTasks.removeAll { $0.id == taskId }
                   updateDockBadge()
                   objectWillChange.send()
               }
           }
       }
   }

    private func fetchProductsWithRetry() async {
        guard !isFetchingProducts else { return }
        
        isFetchingProducts = true
        loadingState = .loading
        
        let maxRetries = 3
        var retryCount = 0
        
        while retryCount < maxRetries {
            do {
                let (saps, cdn, sapCodes) = try await fetchProductsData()

                await MainActor.run {
                    self.saps = saps
                    self.cdn = cdn
                    self.sapCodes = sapCodes
                    self.loadingState = .success
                    self.isFetchingProducts = false
                }
                return
            } catch {
                retryCount += 1
                if retryCount == maxRetries {
                    await MainActor.run {
                        self.loadingState = .failed(error)
                        self.isFetchingProducts = false
                    }
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(retryCount))) * 1_000_000_000)
                }
            }
        }
    }

   private func clearCompletedDownloadTasks() async {
       await MainActor.run {
           downloadTasks.removeAll { task in
               task.status.isCompleted || task.status.isFailed
           }
           updateDockBadge()
           objectWillChange.send()
       }
   }

    func installProduct(at path: URL) async {
        await MainActor.run {
            installationState = .installing(progress: 0, status: "准备安装...")
        }
        
        do {
            try await installManager.install(at: path) { progress, status in
                // 移除这里的状态更新，让错误直接通过 catch 块处理
            }

            await MainActor.run {
                installationState = .completed
            }
        } catch {
            await MainActor.run {
                // 直接设置错误状态，不要通过 progressHandler 更新
                if let installError = error as? InstallManager.InstallError {
                    switch installError {
                    case .installationFailed(let message):
                        installationState = .failed(InstallManager.InstallError.installationFailed(message))
                    default:
                        installationState = .failed(error)
                    }
                } else {
                    installationState = .failed(error)
                }
            }
        }
    }

    func cancelInstallation() {
        Task {
            await installManager.cancel()
        }
    }

    func retryInstallation(at path: URL) async {
        await MainActor.run {
            installationState = .installing(progress: 0, status: "正在重试安装...")
        }
        
        do {
            // 先尝试使用 retry 方法利用 sudo 缓存）
            try await installManager.retry(at: path) { progress, status in
                Task { @MainActor in
                    if status.contains("完成") || status.contains("成功") {
                        self.installationState = .completed
                    } else {
                        self.installationState = .installing(progress: progress, status: status)
                    }
                }
            }
            
            await MainActor.run {
                installationState = .completed
            }
        } catch {
            if case InstallManager.InstallError.installationFailed(let message) = error,
               message.contains("需要重新输入密码") {
                // 如果是因为需要重新输入密码而失败，则回退到正常安装流程
                await installProduct(at: path)
            } else {
                // 其他错误直接显示
                await MainActor.run {
                    if let installError = error as? InstallManager.InstallError {
                        installationState = .failed(installError)
                    } else {
                        installationState = .failed(error)
                    }
                }
            }
        }
    }

    func getApplicationInfo(buildGuid: String) async throws -> String {
        guard let url = URL(string: NetworkConstants.applicationJsonURL) else {
            throw NetworkError.invalidURL(NetworkConstants.applicationJsonURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        var headers = NetworkConstants.adobeRequestHeaders
        headers["x-adobe-build-guid"] = buildGuid
        headers["Accept"] = "application/json"
        headers["Connection"] = "keep-alive"
        headers["Cookie"] = generateCookie()
        
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }
        
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw NetworkError.invalidData("无法将响应数据转换为字符串")
        }
        
        return jsonString
    }

    func fetchProductsData() async throws -> ([String: Sap], String, [SapCodes]) {
        var components = URLComponents(string: NetworkConstants.productsXmlURL)
        components?.queryItems = [
            URLQueryItem(name: "_type", value: "xml"),
            URLQueryItem(name: "channel", value: "ccm"),
            URLQueryItem(name: "channel", value: "sti"),
            URLQueryItem(name: "platform", value: "osx10-64,osx10,macarm64,macuniversal"),
            URLQueryItem(name: "productType", value: "Desktop")
        ]
        
        guard let url = components?.url else {
            throw NetworkError.invalidURL(NetworkConstants.productsXmlURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        NetworkConstants.adobeRequestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(httpResponse.statusCode, nil)
        }
        
        guard let xmlString = String(data: data, encoding: .utf8) else {
            throw NetworkError.invalidData("无法解码XML数据")
        }

        let result: ([String: Sap], String, [SapCodes]) = try await Task.detached(priority: .userInitiated) {
            let parseResult = try XHXMLParser.parse(xmlString: xmlString)
            let products = parseResult.products, cdn = parseResult.cdn
            var sapCodes: [SapCodes] = []
            let allowedPlatforms = ["macuniversal", "macarm64", "osx10-64", "osx10"]
            for product in products.values {
                if product.isValid {
                    var lastVersion: String? = nil
                    for version in product.versions.values.reversed() {
                        if !version.buildGuid.isEmpty && allowedPlatforms.contains(version.apPlatform) {
                            lastVersion = version.productVersion
                            break
                        }
                    }
                    if lastVersion != nil {
                        sapCodes.append(SapCodes(
                            sapCode: product.sapCode,
                            displayName: product.displayName
                        ))
                    }
                }
            }
            return (products, cdn, sapCodes)
        }.value
        
        return result
    }

    @MainActor
    func updateTaskStatus(_ taskId: UUID, status: DownloadStatus) {
        if let index = downloadTasks.firstIndex(where: { $0.id == taskId }) {
            downloadTasks[index].setStatus(status)
            objectWillChange.send()
        }
    }
}
