import XCTest
import Vision
@testable import thing_finder

class TrackingManagerTests: XCTestCase {
    
    var trackingManager: TrackingManager!
    
    override func setUp() {
        super.setUp()
        trackingManager = TrackingManager()
    }
    
    override func tearDown() {
        trackingManager = nil
        super.tearDown()
    }
    
    func testAddTracking() {
        // Given
        let observation = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        
        // When
        trackingManager.addTracking(request)
        
        // Then
        XCTAssertTrue(trackingManager.hasActiveTracking)
        XCTAssertEqual(trackingManager.trackingRequests.count, 1)
    }
    
    func testAddMultipleTracking() {
        // Given
        let observation1 = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let observation2 = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2))
        let request1 = VNTrackObjectRequest(detectedObjectObservation: observation1)
        let request2 = VNTrackObjectRequest(detectedObjectObservation: observation2)
        
        // When
        trackingManager.addTracking([request1, request2])
        
        // Then
        XCTAssertTrue(trackingManager.hasActiveTracking)
        XCTAssertEqual(trackingManager.trackingRequests.count, 2)
    }
    
    func testClearTracking() {
        // Given
        let observation = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        trackingManager.addTracking(request)
        XCTAssertTrue(trackingManager.hasActiveTracking)
        
        // When
        trackingManager.clearTracking()
        
        // Then
        XCTAssertFalse(trackingManager.hasActiveTracking)
        XCTAssertEqual(trackingManager.trackingRequests.count, 0)
    }
    
    func testClearTrackingExcept() {
        // Given
        let observation1 = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let observation2 = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2))
        let request1 = VNTrackObjectRequest(detectedObjectObservation: observation1)
        let request2 = VNTrackObjectRequest(detectedObjectObservation: observation2)
        trackingManager.addTracking([request1, request2])
        XCTAssertEqual(trackingManager.trackingRequests.count, 2)
        
        // When
        trackingManager.clearTrackingExcept(request1)
        
        // Then
        XCTAssertTrue(trackingManager.hasActiveTracking)
        XCTAssertEqual(trackingManager.trackingRequests.count, 1)
        XCTAssertTrue(trackingManager.trackingRequests.contains(request1))
    }
    
    // Note: Testing performTracking would require a real CVPixelBuffer which is difficult to create in a unit test
    // For a complete test suite, consider using mock objects or integration tests with actual camera frames
}
