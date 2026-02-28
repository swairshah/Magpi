import Foundation
import COnnxRuntime

/// Swift wrapper around the ONNX Runtime C API.
///
/// Provides a clean interface for loading ONNX models and running inference.
/// Used by SileroVAD and SmartTurnDetector.
final class OnnxSession {
    
    enum OnnxError: Error, LocalizedError {
        case runtimeError(String)
        case modelNotFound(String)
        case invalidInput(String)
        case apiInitFailed
        
        var errorDescription: String? {
            switch self {
            case .runtimeError(let msg): return "ONNX Runtime error: \(msg)"
            case .modelNotFound(let path): return "ONNX model not found: \(path)"
            case .invalidInput(let msg): return "Invalid input: \(msg)"
            case .apiInitFailed: return "Failed to initialize ONNX Runtime API"
            }
        }
    }
    
    private let api: UnsafePointer<OrtApi>
    private var env: OpaquePointer?       // OrtEnv*
    private var session: OpaquePointer?   // OrtSession*
    
    /// Load an ONNX model from the given path.
    init(modelPath: String, label: String = "magpi") throws {
        // Get the API
        guard let apiBase = OrtGetApiBase(),
              let api = apiBase.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw OnnxError.apiInitFailed
        }
        self.api = api
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw OnnxError.modelNotFound(modelPath)
        }
        
        // Create environment
        var env: OpaquePointer?
        try check(api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, label, &env))
        self.env = env
        
        // Create session options
        var options: OpaquePointer?
        try check(api.pointee.CreateSessionOptions(&options))
        defer { api.pointee.ReleaseSessionOptions(options) }
        
        // Set to single thread for efficiency
        try check(api.pointee.SetIntraOpNumThreads(options, 1))
        try check(api.pointee.SetInterOpNumThreads(options, 1))
        try check(api.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        
        // Create session
        var session: OpaquePointer?
        try check(api.pointee.CreateSession(env, modelPath, options, &session))
        self.session = session
        
        print("Magpi: ONNX session loaded: \(modelPath)")
    }
    
    deinit {
        if let session = session { api.pointee.ReleaseSession(session) }
        if let env = env { api.pointee.ReleaseEnv(env) }
    }
    
    // MARK: - Tensor Creation
    
    /// Create a float32 tensor from an array.
    /// Uses ORT's allocator so data is copied and owned by the tensor.
    func createFloatTensor(_ data: [Float], shape: [Int64]) throws -> OpaquePointer {
        let totalElements = shape.isEmpty ? 1 : shape.reduce(1, *)
        
        guard data.count == Int(totalElements) else {
            throw OnnxError.invalidInput(
                "Data count \(data.count) doesn't match shape \(shape) (expected \(totalElements))"
            )
        }
        
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try check(api.pointee.GetAllocatorWithDefaultOptions(&allocator))
        
        var tensor: OpaquePointer?
        
        if shape.isEmpty {
            // Scalar tensor
            try check(api.pointee.CreateTensorAsOrtValue(
                allocator, nil, 0,
                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor
            ))
        } else {
            var mutableShape = shape
            try mutableShape.withUnsafeMutableBufferPointer { shapePtr in
                try check(api.pointee.CreateTensorAsOrtValue(
                    allocator, shapePtr.baseAddress, shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor
                ))
            }
        }
        
        // Copy our data into the tensor's own buffer
        var rawPtr: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(tensor, &rawPtr))
        data.withUnsafeBufferPointer { src in
            rawPtr?.copyMemory(from: src.baseAddress!, byteCount: data.count * MemoryLayout<Float>.size)
        }
        
        return tensor!
    }
    
    /// Create an int64 tensor from an array.
    func createInt64Tensor(_ data: [Int64], shape: [Int64]) throws -> OpaquePointer {
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try check(api.pointee.GetAllocatorWithDefaultOptions(&allocator))
        
        var tensor: OpaquePointer?
        
        if shape.isEmpty {
            // Scalar tensor
            try check(api.pointee.CreateTensorAsOrtValue(
                allocator, nil, 0,
                ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &tensor
            ))
        } else {
            var mutableShape = shape
            try mutableShape.withUnsafeMutableBufferPointer { shapePtr in
                try check(api.pointee.CreateTensorAsOrtValue(
                    allocator, shapePtr.baseAddress, shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &tensor
                ))
            }
        }
        
        // Copy our data into the tensor's own buffer
        var rawPtr: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(tensor, &rawPtr))
        data.withUnsafeBufferPointer { src in
            rawPtr?.copyMemory(from: src.baseAddress!, byteCount: data.count * MemoryLayout<Int64>.size)
        }
        
        return tensor!
    }
    
    // MARK: - Inference
    
    /// Run inference with named inputs and outputs.
    ///
    /// - Parameters:
    ///   - inputs: Array of (name, OrtValue tensor) pairs
    ///   - outputNames: Names of output tensors to retrieve
    /// - Returns: Array of OrtValue output tensors (caller must release)
    func run(
        inputs: [(name: String, tensor: OpaquePointer)],
        outputNames: [String]
    ) throws -> [OpaquePointer] {
        
        let inputNames = inputs.map { $0.name }
        let inputTensors = inputs.map { $0.tensor }
        
        // Convert string arrays to C string arrays
        let cInputNames = inputNames.map { strdup($0)! }
        let cOutputNames = outputNames.map { strdup($0)! }
        
        defer {
            cInputNames.forEach { free($0) }
            cOutputNames.forEach { free($0) }
        }
        
        var outputTensors = [OpaquePointer?](repeating: nil, count: outputNames.count)
        
        try cInputNames.withUnsafeBufferPointer { inputNamesPtr in
            try cOutputNames.withUnsafeBufferPointer { outputNamesPtr in
                try inputTensors.withUnsafeBufferPointer { inputTensorsPtr in
                    // Cast to the expected types
                    let inputNamesRaw = UnsafePointer<UnsafePointer<CChar>?>(
                        OpaquePointer(inputNamesPtr.baseAddress!)
                    )
                    let outputNamesRaw = UnsafePointer<UnsafePointer<CChar>?>(
                        OpaquePointer(outputNamesPtr.baseAddress!)
                    )
                    let inputTensorsRaw = UnsafePointer<OpaquePointer?>(
                        OpaquePointer(inputTensorsPtr.baseAddress!)
                    )
                    
                    try check(api.pointee.Run(
                        session,
                        nil,  // run options
                        inputNamesRaw,
                        inputTensorsRaw,
                        inputs.count,
                        outputNamesRaw,
                        outputNames.count,
                        &outputTensors
                    ))
                }
            }
        }
        
        return outputTensors.compactMap { $0 }
    }
    
    // MARK: - Output Extraction
    
    /// Extract float data from an output tensor.
    func getFloatOutput(_ tensor: OpaquePointer) throws -> [Float] {
        var data: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(tensor, &data))
        
        // Get element count via TypeInfo → TensorTypeAndShapeInfo
        var typeInfo: OpaquePointer?
        try check(api.pointee.GetTypeInfo(tensor, &typeInfo))
        defer { if let ti = typeInfo { api.pointee.ReleaseTypeInfo(ti) } }
        
        var tensorInfo: OpaquePointer?
        try check(api.pointee.CastTypeInfoToTensorInfo(typeInfo, &tensorInfo))
        // Note: tensorInfo is owned by typeInfo, don't release separately
        
        var elementCount: Int = 0
        try check(api.pointee.GetTensorShapeElementCount(tensorInfo, &elementCount))
        
        let floatPtr = data!.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: floatPtr, count: elementCount))
    }
    
    /// Release a tensor.
    func releaseTensor(_ tensor: OpaquePointer) {
        api.pointee.ReleaseValue(tensor)
    }
    
    // MARK: - Error Handling
    
    private func check(_ status: OpaquePointer?) throws {
        guard let status = status else { return } // NULL = success
        let msg = api.pointee.GetErrorMessage(status)
        let message = msg.map { String(cString: $0) } ?? "unknown error"
        api.pointee.ReleaseStatus(status)
        throw OnnxError.runtimeError(message)
    }
}
