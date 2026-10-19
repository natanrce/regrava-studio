import CoreImage
import Foundation

/// Core Image kernels compiled from `Kernels/RegravaKernels.metal`.
enum RenderKernels {
    private static let library: Data? = Bundle.module.url(forResource: "RegravaKernels", withExtension: "metallib")
        .flatMap { try? Data(contentsOf: $0) }

    static func color(_ name: String) -> CIColorKernel? {
        library.flatMap { try? CIColorKernel(functionName: name, fromMetalLibraryData: $0) }
    }

    static func general(_ name: String) -> CIKernel? {
        library.flatMap { try? CIKernel(functionName: name, fromMetalLibraryData: $0) }
    }
}
