// PipelineControl.swift
import DaylightKit

/// Implemented by FramePipeline (B); used by InkRouter (B), Hotkeys (B), MirrorController (F), AppModel (B).
protocol PipelineControl: AnyObject {
    func post(_ event: GovernorEvent)
    var governorSnapshot: GovernorOutput { get }
    func setViewerCount(_ n: Int)
    func setPreviewVisible(_ visible: Bool)
    func setSinkConnected(_ connected: Bool)
    var onStateForClients: ((StateReport) -> Void)? { get set }
}
