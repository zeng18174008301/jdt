// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Domain

public struct RemoteRTCMedia: Sendable {
    public let owtBaseURL: String
    public let icePolicy: RTCIcePolicy?
    public let iceServers: [RemoteRTCIceServer]
    public let iceCredentialExpiresAt: String
    public let iceCredentialRefreshAfter: String
    public let turnRouteTelemetry: RemoteRTCTurnRouteTelemetry?

    public init(
        owtBaseURL: String = "",
        iceServers: [RemoteRTCIceServer] = [],
        iceCredentialExpiresAt: String = "",
        iceCredentialRefreshAfter: String = "",
        turnRouteTelemetry: RemoteRTCTurnRouteTelemetry? = nil,
        icePolicy: RTCIcePolicy? = nil
    ) {
        self.owtBaseURL = owtBaseURL
        self.icePolicy = icePolicy
        self.iceServers = iceServers
        self.iceCredentialExpiresAt = iceCredentialExpiresAt
        self.iceCredentialRefreshAfter = iceCredentialRefreshAfter
        self.turnRouteTelemetry = turnRouteTelemetry
    }
}

public struct RemoteRTCIceServer: Decodable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    enum CodingKeys: String, CodingKey {
        case urls
        case username
        case credential
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try? c.decodeIfPresent([String].self, forKey: .urls) {
            urls = array
        } else if let single = try? c.decodeIfPresent(String.self, forKey: .urls) {
            urls = [single]
        } else {
            urls = []
        }
        username = try c.decodeIfPresent(String.self, forKey: .username)
        credential = try c.decodeIfPresent(String.self, forKey: .credential)
    }
}

public struct RemoteRTCIceCredentials: Sendable {
    public let icePolicy: RTCIcePolicy?
    public let iceServers: [RemoteRTCIceServer]
    public let rtcToken: String
    public let iceCredentialExpiresAt: String
    public let iceCredentialRefreshAfter: String
    public let turnRouteTelemetry: RemoteRTCTurnRouteTelemetry?

    public init(
        iceServers: [RemoteRTCIceServer] = [],
        rtcToken: String = "",
        iceCredentialExpiresAt: String = "",
        iceCredentialRefreshAfter: String = "",
        turnRouteTelemetry: RemoteRTCTurnRouteTelemetry? = nil,
        icePolicy: RTCIcePolicy? = nil
    ) {
        self.icePolicy = icePolicy
        self.iceServers = iceServers
        self.rtcToken = rtcToken
        self.iceCredentialExpiresAt = iceCredentialExpiresAt
        self.iceCredentialRefreshAfter = iceCredentialRefreshAfter
        self.turnRouteTelemetry = turnRouteTelemetry
    }
}

public struct RemoteRTCTurnRouteTelemetry: Decodable, Sendable, Equatable {
    public struct Node: Decodable, Sendable, Equatable {
        public let nodeID: String
        public let urls: [String]
        public init(nodeID: String, urls: [String]) { self.nodeID = nodeID; self.urls = urls }
        enum CodingKeys: String, CodingKey { case nodeID = "node_id", urls }
    }
    public let schemaVersion: String
    public let mappingVersion: String
    public let nodes: [Node]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", mappingVersion = "mapping_version", nodes
    }

    public init(schemaVersion: String, mappingVersion: String, nodes: [Node]) {
        self.schemaVersion = schemaVersion
        self.mappingVersion = mappingVersion
        self.nodes = nodes
    }
}

public struct RTCTurnRouteObservation: Sendable, Equatable {
    public struct Transport: Sendable, Equatable {
        public let transportID: Int
        public let routeEpoch: Int
        public let selectionBasis: String
        public let localCandidateType: String
        public let remoteCandidateType: String
        public let localRelayProtocol: String
        public let nodeID: String?
        public let unknownReason: String
        public let bytesSent: Int64?
        public let bytesReceived: Int64?


        public init(transportID: Int, routeEpoch: Int, selectionBasis: String, localCandidateType: String, remoteCandidateType: String, localRelayProtocol: String, nodeID: String?, unknownReason: String, bytesSent: Int64?, bytesReceived: Int64?) {
            self.transportID = transportID
            self.routeEpoch = routeEpoch
            self.selectionBasis = selectionBasis
            self.localCandidateType = localCandidateType
            self.remoteCandidateType = remoteCandidateType
            self.localRelayProtocol = localRelayProtocol
            self.nodeID = nodeID
            self.unknownReason = unknownReason
            self.bytesSent = bytesSent
            self.bytesReceived = bytesReceived
        }
    }
    public let connectionID: String
    public let mappingVersion: String
    public let transports: [Transport]
    public init(connectionID: String, mappingVersion: String, transports: [Transport]) {
        self.connectionID = connectionID
        self.mappingVersion = mappingVersion
        self.transports = transports
    }
}

public struct RTCQualitySample: Sendable, Equatable {
    public let sampledAt: Date
    public let sampleSeq: Int64
    public let connectionRoute: String
    public let candidateProtocol: String
    public let rttMS: Double?
    public let jitterMS: Double?
    public let packetLossPct: Double?
    public let availableOutgoingBitrateKbps: Double?
    public let inboundBitrateKbps: Double?
    public let outboundBitrateKbps: Double?
    public let framesPerSecond: Double?
    public let framesDropped: Int64?
    public let audioConcealmentPct: Double?
    public let freezeCount: Int64?
    public var routeObservation: RTCTurnRouteObservation? = nil

    public init(sampledAt: Date, sampleSeq: Int64, connectionRoute: String, candidateProtocol: String, rttMS: Double?, jitterMS: Double?, packetLossPct: Double?, availableOutgoingBitrateKbps: Double?, inboundBitrateKbps: Double?, outboundBitrateKbps: Double?, framesPerSecond: Double?, framesDropped: Int64?, audioConcealmentPct: Double?, freezeCount: Int64?, routeObservation: RTCTurnRouteObservation? = nil) {
        self.sampledAt = sampledAt
        self.sampleSeq = sampleSeq
        self.connectionRoute = connectionRoute
        self.candidateProtocol = candidateProtocol
        self.rttMS = rttMS
        self.jitterMS = jitterMS
        self.packetLossPct = packetLossPct
        self.availableOutgoingBitrateKbps = availableOutgoingBitrateKbps
        self.inboundBitrateKbps = inboundBitrateKbps
        self.outboundBitrateKbps = outboundBitrateKbps
        self.framesPerSecond = framesPerSecond
        self.framesDropped = framesDropped
        self.audioConcealmentPct = audioConcealmentPct
        self.freezeCount = freezeCount
        self.routeObservation = routeObservation
    }
}

public struct RemoteRTCQualityBatchResult: Decodable, Sendable, Equatable {
    public let schemaVersion: String
    public let acceptedCount: Int64
    public let duplicateCount: Int64

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case acceptedCount = "accepted_count"
        case duplicateCount = "duplicate_count"
    }
    public init(schemaVersion: String, acceptedCount: Int64, duplicateCount: Int64) {
        self.schemaVersion = schemaVersion
        self.acceptedCount = acceptedCount
        self.duplicateCount = duplicateCount
    }
}
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END
