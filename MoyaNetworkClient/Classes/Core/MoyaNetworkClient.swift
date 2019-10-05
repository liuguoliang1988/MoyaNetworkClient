import Moya

public typealias Result<Success> = Swift.Result<Success, Error>
public typealias Completion<Value> = (Result<Value>) -> Void

public typealias DefaultMoyaNetworkClient = MoyaNetworkClient<MoyaNCError>

internal class SimpleCancellable: Cancellable {
    var isCancelled = false
    func cancel() {
        isCancelled = true
    }
}

public class MoyaNetworkClient<ErrorType: Error & Decodable> {

    private var jsonDecoder: JSONDecoder
    private var provider: MoyaProvider<MultiTarget>
    private var requests = [String: Request]()

    public init(jsonDecoder: JSONDecoder = JSONDecoder(),
                provider: MoyaProvider<MultiTarget> = MoyaProvider<MultiTarget>(plugins: [NetworkLoggerPlugin(verbose: true)])) {
        self.jsonDecoder = jsonDecoder
        self.provider = provider
    }

    @discardableResult public func request<Value: Codable>(_ target: BaseTargetType, _ completion: @escaping Completion<Value>) -> Request {
        return providerRequest(target, completion)
    }

    @discardableResult public func request<Value: Codable>(_ target: BaseTargetType) -> FutureResult<Value> {
        return FutureResult<Value> { completion in
            self.providerRequest(target) { (result: Result<Value>) in
                switch result {
                case let .success(value): completion(.success(value))
                case let .failure(error): completion(.failure(error))
                }
            }
        }
    }

    // MARK: Private Methods
    @discardableResult private func providerRequest<Value: Codable>(_ target: BaseTargetType, _ completion: @escaping Completion<Value>) -> Request {
        #if canImport(Cache)
        if let request = processCache(target, completion) {
            return request
        }
        #endif
        let requestId = UUID().uuidString
        let cancelable = provider.request(MultiTarget(target)) { result in
            switch result {
            case let .success(response):
                self.process(response: response, target, completion)
            case let .failure(error):
                if self.isCancelledError(error, requestId: requestId) { return }
                let error = self.process(error: error, response: error.response)
                print("There was something wrong with the request! Error: \(error)")
                completion(.failure(error))
            }
            objc_sync_enter(self)
            self.requests.removeValue(forKey: requestId)
            objc_sync_exit(self)
        }
        objc_sync_enter(self)
        let request = RequestAdapter(cancellable: cancelable)
        requests[requestId] = request
        objc_sync_exit(self)
        return request
    }

    private func process<Value: Codable>(response: Response, _ target: BaseTargetType, _ completion: @escaping Completion<Value>) {
        do {
            let response = try response.filterSuccessfulStatusCodes()
            var result: Value
            switch Value.self {
            case is URL.Type: result = target.destinationURL as! Value
            case is Data.Type: result = response.data as! Value
            default: result = try response.map(Value.self, atKeyPath: target.keyPath, using: self.jsonDecoder, failsOnEmptyData: false)
            }
            #if canImport(Cache)
            objc_sync_enter(self)
            ResponseCache.cacheData(target, data: response)
            objc_sync_exit(self)
            #endif
            completion(.success(result))
        } catch let error {
            if let result = try? response.mapJSON(), let object = result as? Value {
                #if canImport(Cache)
                objc_sync_enter(self)
                ResponseCache.cacheData(target, data: response)
                objc_sync_exit(self)
                #endif
                completion(.success(object))
                return
            }
            let error = self.process(error: error, response: response)
            completion(.failure(error))
        }
    }

    #if canImport(Cache)
    private func processCache<Value: Codable>(_ target: BaseTargetType, _ completion: @escaping Completion<Value>) -> Request? {
        let responseCache: () -> Response? = {
            let cacheKey = ResponseCache.uniqueKey(target)
            return try? ResponseCache.shared.responseStorage?.object(forKey: cacheKey)
        }

        switch target.cachePolicy {
            // TODO: Process all cachePolicy
        case .useProtocolCachePolicy, .reloadIgnoringLocalCacheData, .reloadIgnoringLocalAndRemoteCacheData, .reloadRevalidatingCacheData:
            break
        case .returnCacheDataElseLoad:
            if let responseCache = responseCache() {
                process(response: responseCache, target, completion)
                return RequestAdapter(cancellable: SimpleCancellable())
            }
        case .returnCacheDataDontLoad:
            if let responseCache = responseCache() {
                process(response: responseCache, target, completion)
            } else {
                // TODO: Return error
            }
            return RequestAdapter(cancellable: SimpleCancellable())
        @unknown default: break
        }
        return nil
    }
    #endif

    private func process(error: Error, response: Response?) -> Error {
        if let response = response, let customError = try? response.map(ErrorType.self) { return customError }
        return error
    }

    private func isCancelledError(_ error: MoyaError, requestId: String) -> Bool {
        guard case .underlying(let swiftError, _) = error else { return false }
        objc_sync_enter(self)
        guard let currentRequest = requests[requestId] else { return false }
        objc_sync_exit(self)
        return (swiftError as NSError).code == NSURLErrorCancelled && currentRequest.isCancelled
    }
}