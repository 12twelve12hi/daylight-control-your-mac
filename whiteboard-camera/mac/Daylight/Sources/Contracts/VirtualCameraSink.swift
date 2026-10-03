// VirtualCameraSink.swift
import CoreMedia
import DaylightKit

enum SinkStatus: Equatable {
    case notInstalled            // extension not activated yet
    case awaitingApproval        // activation submitted, System Settings approval pending
    case installed               // device visible, sink stream not open
    case connected               // sink stream open, frames flow
    case error(FailureText.Case, String)
}

/// Implemented by CMIOSinkClient (C) and PreviewOnlySink (C); FakeSink in DaylightTests (B).
protocol VirtualCameraSink: AnyObject {
    var status: SinkStatus { get }
    var onStatusChange: ((SinkStatus) -> Void)? { get set }
    var onQueueAltered: (() -> Void)? { get set }
    var viewerCount: Int { get }                        // 0 when unknown or not connected
    var onViewerCount: ((Int) -> Void)? { get set }
    func start()
    func stop()
    @discardableResult func push(_ sampleBuffer: CMSampleBuffer) -> Bool   // never blocks; false when dropped
}
