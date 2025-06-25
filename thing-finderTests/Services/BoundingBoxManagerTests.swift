import XCTest
import Vision
import SwiftUI
@testable import thing_finder

class BoundingBoxManagerTests: XCTestCase {
    
    var boundingBoxManager: BoundingBoxManager!
    var mockImageUtilities: MockImageUtilities!
    
    override func setUp() {
        super.setUp()
        mockImageUtilities = MockImageUtilities()
        boundingBoxManager = BoundingBoxManager(imgUtils: mockImageUtilities)
    }
    
    override func tearDown() {
        boundingBoxManager = nil
        mockImageUtilities = nil
        super.tearDown()
    }
    
    func testBoundingBoxManagerImplementsBoundingBoxCreator() {
        // Verify that BoundingBoxManager conforms to BoundingBoxCreator protocol
        XCTAssertTrue(boundingBoxManager is BoundingBoxCreator)
    }
    
    func testCreateBoundingBox() {
        // Create a mock observation
        let boundingBox = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let observation = MockVNRecognizedObjectObservation(boundingBox: boundingBox)
        
        // Define test parameters
        let bufferSize = CGSize(width: 1920, height: 1080)
        let viewSize = CGSize(width: 390, height: 844)
        let label = "Test Object"
        let color = Color.yellow
        
        // Mock the unscaledBoundingBoxes method to return predictable rectangles
        let imageRect = CGRect(x: 480, y: 270, width: 960, height: 540)
        let viewRect = CGRect(x: 97.5, y: 211, width: 195, height: 422)
        mockImageUtilities.mockImageRect = imageRect
        mockImageUtilities.mockViewRect = viewRect
        
        // Call the method under test
        let result = boundingBoxManager.createBoundingBox(
            from: observation,
            bufferSize: bufferSize,
            viewSize: viewSize,
            imageToViewRect: mockImageUtilities.imageRectToViewRect,
            scalingOption: .avfoundation,
            label: label,
            color: color
        )
        
        // Verify the result
        XCTAssertEqual(result.imageRect, imageRect)
        XCTAssertEqual(result.viewRect, viewRect)
        XCTAssertEqual(result.label, label)
        XCTAssertEqual(result.color, color)
        XCTAssertEqual(result.alpha, Double(observation.confidence))
    }
}

// MARK: - Mock Classes

class MockImageUtilities: ImageUtilities {
    var mockImageRect: CGRect = .zero
    var mockViewRect: CGRect = .zero
    
    func unscaledBoundingBoxes(
        for boundingBox: CGRect,
        imageSize: CGSize,
        viewSize: CGSize,
        imageToView: @escaping (CGRect, (CGSize, CGSize)) -> CGRect,
        options: ScalingOptions
    ) -> (CGRect, CGRect) {
        return (mockImageRect, mockViewRect)
    }
    
    func imageRectToViewRect(_ rect: CGRect, _ sizes: (CGSize, CGSize)) -> CGRect {
        return mockViewRect
    }
}

class MockVNRecognizedObjectObservation: VNRecognizedObjectObservation {
    private let mockBoundingBox: CGRect
    private let mockConfidence: Float = 0.95
    
    init(boundingBox: CGRect) {
        self.mockBoundingBox = boundingBox
        super.init(requestRevision: 0)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var boundingBox: CGRect {
        return mockBoundingBox
    }
    
    override var confidence: Float {
        return mockConfidence
    }
    
    override var labels: [VNClassificationObservation] {
        return []
    }
}
