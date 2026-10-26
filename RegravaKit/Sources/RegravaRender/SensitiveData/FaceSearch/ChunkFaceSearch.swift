import CoreGraphics
import Dispatch
import Foundation

extension SD {
    /// The per-read face submission of a chunk scan. Each read gets a prepare operation and a plan operation; plans run in submission order
    /// (each depends on the previous one), so the shared cache sees the reads in order. At most 8
    /// reads are pending (the semaphore is signalled once the read's findings are delivered).
    final class ChunkFaceSearch {
        let cache: FaceSearchCache
        let queue: OperationQueue
        let pending: DispatchSemaphore
        var lastPlan: Operation?

        /// `Box` (private generic class, used as `Box<GrayImage?>` and `Box<[FaceSearchArea]?>`).
        /// The name of its single stored `var`.
        private final class Box<T> {
            var value: T
            init(_ value: T) { self.value = value }
        }

        init(queue: OperationQueue) {
            cache = FaceSearchCache()
            pending = DispatchSemaphore(value: 8)
            lastPlan = nil
            self.queue = queue
        }

        func submit(_ image: GrayImage, looksOfArea: @escaping (CGRect) -> [ArraySlice<UInt8>]?, priority: Operation.QueuePriority,
                    found: @escaping ([Finding]) -> Void) {
            let pending = pending
            pending.wait()
            let imageBox = Box<GrayImage?>(image)
            let areasBox = Box<[FaceSearchArea]?>(nil)
            // Prepare: the photo areas of the read.
            let prepare = BlockOperation {
                autoreleasepool {
                    areasBox.value = imageBox.value.map { SD.prepareFaceSearch(in: $0, looksOfArea: looksOfArea) }
                }
                imageBox.value = nil
            }
            let cache = cache, queue = queue
            // Plan: match the areas against the cache, queue the new searches and the delivery.
            let plan = BlockOperation {
                let (searches, newSearches) = cache.plan(areasBox.value ?? [], isQueued: true)
                areasBox.value = nil
                // Deliver once every search the read uses has run.
                let finish = BlockOperation {
                    found(SD.faceFindings(searches))
                    pending.signal()
                }
                for search in searches {
                    if let operation = search.operation { finish.addDependency(operation) }
                }
                var operations = newSearches.compactMap { $0.operation }
                operations.append(contentsOf: [finish])
                for operation in operations {
                    operation.queuePriority = priority
                }
                queue.addOperations(operations, waitUntilFinished: false)
            }
            plan.addDependency(prepare)
            if let lastPlan {
                plan.addDependency(lastPlan)
            }
            lastPlan = plan
            prepare.queuePriority = priority
            plan.queuePriority = priority
            queue.addOperations([prepare, plan], waitUntilFinished: false)
        }
    }
}
