import XCTest
import Combine
@testable import thing_finder

class FPSManagerTests: XCTestCase {
    
    var fpsManager: FPSManager!
    private var cancellables: Set<AnyCancellable> = []
    
    override func setUp() {
        super.setUp()
        fpsManager = FPSManager()
    }
    
    override func tearDown() {
        cancellables.removeAll()
        fpsManager = nil
        super.tearDown()
    }
    
    func testInitialFPSValue() {
        // When initialized, FPS should be 0
        XCTAssertEqual(fpsManager.currentFPS, 0.0)
    }
    
    func testFPSCalculation() {
        // Given
        let expectation = self.expectation(description: "FPS updated")
        var updatedFPS: Double = 0.0
        
        // When
        fpsManager.fpsPublisher
            .sink { fps in
                updatedFPS = fps
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        // Simulate multiple frames within a short time
        for _ in 0..<10 {
            fpsManager.updateFPSCalculation()
            // Small delay to simulate frame processing
            usleep(10000) // 10ms
        }
        
        // Then
        waitForExpectations(timeout: 1.0, handler: nil)
        
        // FPS should be greater than 0 after processing frames
        XCTAssertGreaterThan(updatedFPS, 0.0)
        // FPS should be capped at 60
        XCTAssertLessThanOrEqual(updatedFPS, 60.0)
    }
    
    func testFPSPublisher() {
        // Given
        let expectation = self.expectation(description: "FPS publisher emits")
        var receivedValue = false
        
        // When
        fpsManager.fpsPublisher
            .sink { _ in
                receivedValue = true
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        fpsManager.updateFPSCalculation()
        
        // Then
        waitForExpectations(timeout: 1.0, handler: nil)
        XCTAssertTrue(receivedValue, "FPS publisher should emit a value")
    }
}
