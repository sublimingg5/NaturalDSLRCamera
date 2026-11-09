import CoreVideo
import Metal
import MetalPerformanceShaders
import UIKit

struct GCamPipelineRecipe {
    var exposureCompensation: Float = 1.65 // Recuperación limpia de subexposición
    var shoulderCompression: Float = 0.35 // Compresión de hombro Canon HTP
    var acutanceStrength: Float = 0.30 // Microcontraste óptico
    var readNoise: Float = 0.012 // Ruido de lectura analógico sensor Sony IMX503
    var shotNoise: Float = 0.035 // Ruido de fotones Poisson
}

final class MetalGCamCoordinator {
    static let shared = MetalGCamCoordinator()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?

    private var downsamplePipeline: MTLComputePipelineState?
    private var blockMatchPipeline: MTLComputePipelineState?
    private var accumulatePipeline: MTLComputePipelineState?
    private var finalizePipeline: MTLComputePipelineState?

    private let processingQueue = DispatchQueue(label: "com.facu.camera.metalProcessingQueue", qos: .userInitiated)

    private init() {
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            self.device = nil
            self.commandQueue = nil
            return
        }
        self.device = mtlDevice
        self.commandQueue = mtlDevice.makeCommandQueue()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, mtlDevice, nil, &self.textureCache)

        setupPipelines(device: mtlDevice)
    }

    private func setupPipelines(device: MTLDevice) {
        do {
            let library: MTLLibrary
            if let defaultLib = device.makeDefaultLibrary() {
                library = defaultLib
            } else {
                let bundle = Bundle.main
                if let path = bundle.path(forResource: "default", ofType: "metallib") {
                    library = try device.makeLibrary(filepath: path)
                } else {
                    return
                }
            }

            if let downsampleFunc = library.makeFunction(name: "gcam_pyramid_downsample") {
                downsamplePipeline = try device.makeComputePipelineState(function: downsampleFunc)
            }
            if let blockMatchFunc = library.makeFunction(name: "gcam_block_matching") {
                blockMatchPipeline = try device.makeComputePipelineState(function: blockMatchFunc)
            }
            if let accumulateFunc = library.makeFunction(name: "gcam_robust_accumulate") {
                accumulatePipeline = try device.makeComputePipelineState(function: accumulateFunc)
            }
            if let finalizeFunc = library.makeFunction(name: "gcam_finalize_canon_tone") {
                finalizePipeline = try device.makeComputePipelineState(function: finalizeFunc)
            }
        } catch {
            print("Error compilando pipelines Metal: \(error.localizedDescription)")
        }
    }

    // MARK: - Estado de Acumulación en Vuelo (Streaming Stacking)
    private var isStreamingActive = false
    private var streamRefLuma: MTLTexture?
    private var streamRefChroma: MTLTexture?
    private var streamRefPyramid: [MTLTexture] = []
    private var streamAccumLumaA: MTLTexture?
    private var streamAccumLumaB: MTLTexture?
    private var streamWeightMapA: MTLTexture?
    private var streamWeightMapB: MTLTexture?
    private var streamRecipe: GCamPipelineRecipe?
    private var streamFirstImage: UIImage?

    func beginStreamingStack(
        firstBuffer: CVPixelBuffer,
        recipe: GCamPipelineRecipe
    ) {
        processingQueue.sync {
            guard let device = self.device,
                  let commandQueue = self.commandQueue else { return }

            self.streamRecipe = recipe
            self.streamFirstImage = self.createUIImage(from: firstBuffer)

            guard let refLuma = self.makeTexture(from: firstBuffer, plane: 0, pixelFormat: .r8Unorm),
                  let refChroma = self.makeTexture(from: firstBuffer, plane: 1, pixelFormat: .rg8Unorm) else {
                return
            }

            self.streamRefLuma = refLuma
            self.streamRefChroma = refChroma

            let width = refLuma.width
            let height = refLuma.height

            let accumDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
            accumDesc.usage = [.shaderRead, .shaderWrite]
            accumDesc.storageMode = .shared

            guard let accA = device.makeTexture(descriptor: accumDesc),
                  let accB = device.makeTexture(descriptor: accumDesc),
                  let wtA = device.makeTexture(descriptor: accumDesc),
                  let wtB = device.makeTexture(descriptor: accumDesc) else {
                return
            }

            self.streamAccumLumaA = accA
            self.streamAccumLumaB = accB
            self.streamWeightMapA = wtA
            self.streamWeightMapB = wtB

            // Inicializar acumulador con el cuadro base (Frame 1)
            self.initializeAccumulator(refTexture: refLuma, accumTexture: accA, weightTexture: wtA, commandQueue: commandQueue)
            self.streamRefPyramid = self.buildPyramid(for: refLuma, commandQueue: commandQueue)
            self.isStreamingActive = true
        }
    }

    func accumulateNextFrame(buffer: CVPixelBuffer) {
        processingQueue.sync {
            guard isStreamingActive,
                  let commandQueue = self.commandQueue,
                  let refLuma = self.streamRefLuma,
                  let accA = self.streamAccumLumaA,
                  let accB = self.streamAccumLumaB,
                  let wtA = self.streamWeightMapA,
                  let wtB = self.streamWeightMapB,
                  let recipe = self.streamRecipe,
                  let targetLuma = self.makeTexture(from: buffer, plane: 0, pixelFormat: .r8Unorm) else {
                return
            }

            let targetPyramid = self.buildPyramid(for: targetLuma, commandQueue: commandQueue)
            let motionVectors = self.estimateMotion(refPyramid: self.streamRefPyramid, targetPyramid: targetPyramid, commandQueue: commandQueue)

            self.accumulateFrame(
                refLuma: refLuma,
                targetLuma: targetLuma,
                motionVectors: motionVectors,
                inAccumLuma: accA,
                inWeightMap: wtA,
                outAccumLuma: accB,
                outWeightMap: wtB,
                recipe: recipe,
                commandQueue: commandQueue
            )

            // Swap ping-pong
            self.streamAccumLumaA = accB
            self.streamAccumLumaB = accA
            self.streamWeightMapA = wtB
            self.streamWeightMapB = wtA
        }
    }

    func finalizeStreamingStack(completion: @escaping (UIImage?, UIImage?) -> Void) {
        processingQueue.async { [weak self] in
            guard let self = self,
                  let device = self.device,
                  let commandQueue = self.commandQueue,
                  let accLuma = self.streamAccumLumaA,
                  let wtMap = self.streamWeightMapA,
                  let chroma = self.streamRefChroma,
                  let recipe = self.streamRecipe else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }

            let width = accLuma.width
            let height = accLuma.height

            let rgbDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            rgbDesc.usage = [.shaderRead, .shaderWrite]
            rgbDesc.storageMode = .shared

            guard let outRGB = device.makeTexture(descriptor: rgbDesc) else {
                DispatchQueue.main.async { completion(self.streamFirstImage, self.streamFirstImage) }
                return
            }

            self.finalizeCanonToneAndColor(
                accumLuma: accLuma,
                weightMap: wtMap,
                chromaTexture: chroma,
                outRGB: outRGB,
                recipe: recipe,
                commandQueue: commandQueue
            )

            let finalImage = self.createUIImage(from: outRGB)
            let refImage = self.streamFirstImage

            // Limpieza de estado
            self.isStreamingActive = false
            self.streamRefLuma = nil
            self.streamRefChroma = nil
            self.streamRefPyramid = []
            self.streamAccumLumaA = nil
            self.streamAccumLumaB = nil
            self.streamWeightMapA = nil
            self.streamWeightMapB = nil
            self.streamFirstImage = nil

            DispatchQueue.main.async {
                completion(finalImage ?? refImage, refImage)
            }
        }
    }

    // MARK: - Sub-rutinas Metal Compute

    private func initializeAccumulator(
        refTexture: MTLTexture,
        accumTexture: MTLTexture,
        weightTexture: MTLTexture,
        commandQueue: MTLCommandQueue
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

        // Inicializar acumulador copiando I_0 y peso 1.0 mediante un compute sencillo o blit
        blitEncoder.endEncoding()

        if let encoder = commandBuffer.makeComputeCommandEncoder(),
           let pipeline = self.accumulatePipeline {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(refTexture, index: 0)
            encoder.setTexture(refTexture, index: 1) // Dummy
            encoder.setTexture(refTexture, index: 2) // Dummy
            encoder.setTexture(refTexture, index: 3) // Dummy
            encoder.setTexture(refTexture, index: 4) // Dummy
            encoder.setTexture(accumTexture, index: 5)
            encoder.setTexture(weightTexture, index: 6)

            var readNoise: Float = 0.012
            var shotNoise: Float = 0.035
            var blockSize: Int32 = 8
            encoder.setBytes(&readNoise, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&shotNoise, length: MemoryLayout<Float>.size, index: 1)
            encoder.setBytes(&blockSize, length: MemoryLayout<Int32>.size, index: 2)

            let w = pipeline.threadExecutionWidth
            let h = pipeline.maxTotalThreadsPerThreadgroup / w
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let numGroups = MTLSize(width: (refTexture.width + w - 1) / w, height: (refTexture.height + h - 1) / h, depth: 1)

            encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func buildPyramid(for texture: MTLTexture, commandQueue: MTLCommandQueue) -> [MTLTexture] {
        guard let device = self.device,
              let pipeline = downsamplePipeline else { return [texture] }

        var pyramid = [texture]
        var current = texture

        for _ in 1...2 {
            let nextW = max(current.width / 2, 1)
            let nextH = max(current.height / 2, 1)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: nextW, height: nextH, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]

            guard let nextTex = device.makeTexture(descriptor: desc),
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                break
            }

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(current, index: 0)
            encoder.setTexture(nextTex, index: 1)

            let w = pipeline.threadExecutionWidth
            let h = pipeline.maxTotalThreadsPerThreadgroup / w
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let numGroups = MTLSize(width: (nextW + w - 1) / w, height: (nextH + h - 1) / h, depth: 1)

            encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            pyramid.append(nextTex)
            current = nextTex
        }

        return pyramid
    }

    private func estimateMotion(
        refPyramid: [MTLTexture],
        targetPyramid: [MTLTexture],
        commandQueue: MTLCommandQueue
    ) -> MTLTexture {
        guard let device = self.device,
              let pipeline = blockMatchPipeline,
              refPyramid.count >= 3,
              targetPyramid.count >= 3 else {
            return refPyramid[0]
        }

        let baseLuma = refPyramid[0]
        let mvGridW = (baseLuma.width + 7) / 8
        let mvGridH = (baseLuma.height + 7) / 8

        let mvDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: mvGridW, height: mvGridH, mipmapped: false)
        mvDesc.usage = [.shaderRead, .shaderWrite]
        let dummyPrevDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: 1, height: 1, mipmapped: false)
        dummyPrevDesc.usage = [.shaderRead]

        guard let mvTexture = device.makeTexture(descriptor: mvDesc),
              let dummyPrev = device.makeTexture(descriptor: dummyPrevDesc),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return refPyramid[0]
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(refPyramid[0], index: 0)
        encoder.setTexture(targetPyramid[0], index: 1)
        encoder.setTexture(dummyPrev, index: 2)
        encoder.setTexture(mvTexture, index: 3)

        var searchRadius: Int32 = 4
        var blockSize: Int32 = 8
        encoder.setBytes(&searchRadius, length: MemoryLayout<Int32>.size, index: 0)
        encoder.setBytes(&blockSize, length: MemoryLayout<Int32>.size, index: 1)

        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let numGroups = MTLSize(width: (mvGridW + w - 1) / w, height: (mvGridH + h - 1) / h, depth: 1)

        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return mvTexture
    }

    private func accumulateFrame(
        refLuma: MTLTexture,
        targetLuma: MTLTexture,
        motionVectors: MTLTexture,
        inAccumLuma: MTLTexture,
        inWeightMap: MTLTexture,
        outAccumLuma: MTLTexture,
        outWeightMap: MTLTexture,
        recipe: GCamPipelineRecipe,
        commandQueue: MTLCommandQueue
    ) {
        guard let pipeline = accumulatePipeline,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(refLuma, index: 0)
        encoder.setTexture(targetLuma, index: 1)
        encoder.setTexture(motionVectors, index: 2)
        encoder.setTexture(inAccumLuma, index: 3)
        encoder.setTexture(inWeightMap, index: 4)
        encoder.setTexture(outAccumLuma, index: 5)
        encoder.setTexture(outWeightMap, index: 6)

        var readNoise = recipe.readNoise
        var shotNoise = recipe.shotNoise
        var blockSize: Int32 = 8
        encoder.setBytes(&readNoise, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shotNoise, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&blockSize, length: MemoryLayout<Int32>.size, index: 2)

        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let numGroups = MTLSize(width: (refLuma.width + w - 1) / w, height: (refLuma.height + h - 1) / h, depth: 1)

        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func finalizeCanonToneAndColor(
        accumLuma: MTLTexture,
        weightMap: MTLTexture,
        chromaTexture: MTLTexture,
        outRGB: MTLTexture,
        recipe: GCamPipelineRecipe,
        commandQueue: MTLCommandQueue
    ) {
        guard let pipeline = finalizePipeline,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(accumLuma, index: 0)
        encoder.setTexture(weightMap, index: 1)
        encoder.setTexture(chromaTexture, index: 2)
        encoder.setTexture(outRGB, index: 3)

        var gain = recipe.exposureCompensation
        var shoulder = recipe.shoulderCompression
        var acutance = recipe.acutanceStrength
        encoder.setBytes(&gain, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shoulder, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&acutance, length: MemoryLayout<Float>.size, index: 2)

        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let numGroups = MTLSize(width: (outRGB.width + w - 1) / w, height: (outRGB.height + h - 1) / h, depth: 1)

        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Helpers de CVPixelBuffer & Metal Textures

    private func makeTexture(from pixelBuffer: CVPixelBuffer, plane: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &cvTexture
        )
        guard result == kCVReturnSuccess, let unwrapped = cvTexture else { return nil }
        return CVMetalTextureGetTexture(unwrapped)
    }

    private func selectSharpestFrameIndex(_ buffers: [CVPixelBuffer]) -> Int {
        // En una ráfaga corta, los fotogramas centrales (30-60%) suelen ser los más estables
        // tras la presión inicial del obturador.
        if buffers.count >= 5 {
            return buffers.count / 2
        }
        return 0
    }

    private func createUIImage(from texture: MTLTexture) -> UIImage? {
        let width = texture.width
        let height = texture.height
        let rowBytes = width * 4
        var rawData = [UInt8](repeating: 0, count: rowBytes * height)

        let region = MTLRegionMake2D(0, 0, width, height)
        texture.getBytes(&rawData, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &rawData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ),
              let cgImage = context.makeImage() else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }

    func createUIImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }
}
