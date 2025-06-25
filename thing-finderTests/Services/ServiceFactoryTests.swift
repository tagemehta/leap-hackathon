import XCTest
@testable import thing_finder

class ServiceFactoryTests: XCTestCase {
    
    var serviceFactory: ServiceFactory!
    
    override func setUp() {
        super.setUp()
        serviceFactory = ServiceFactory()
    }
    
    override func tearDown() {
        serviceFactory = nil
        super.tearDown()
    }
    
    func testCreateCameraService() {
        // When
        let cameraService = serviceFactory.createCameraService()
        
        // Then
        XCTAssertNotNil(cameraService)
        XCTAssertNotNil(cameraService.fpsCalculator)
        XCTAssertNotNil(cameraService.objectTracker)
        XCTAssertNotNil(cameraService.objectDetector)
        XCTAssertNotNil(cameraService.boundingBoxCreator)
        XCTAssertNotNil(cameraService.stateController)
        
        // Verify that objectTracker is an instance of TrackingManager
        XCTAssertTrue(cameraService.objectTracker is TrackingManager)
    }
    
    func testObjectTrackerImplementation() {
        // When
        let cameraService = serviceFactory.createCameraService()
        let objectTracker = cameraService.objectTracker
        
        // Then
        // Test basic functionality of the tracker
        XCTAssertFalse(objectTracker.hasActiveTracking)
        
        // Add a tracking request and verify it's tracked
        let observation = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        objectTracker.addTracking(request)
        
        XCTAssertTrue(objectTracker.hasActiveTracking)
        
        // Clear tracking and verify it's cleared
        objectTracker.clearTracking()
        XCTAssertFalse(objectTracker.hasActiveTracking)
    }
}
