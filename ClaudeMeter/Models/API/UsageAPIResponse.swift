//
//  UsageAPIResponse.swift
//  ClaudeMeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// API response for usage data
///
/// Every limit is optional: Claude has moved plans from a 5-hour session limit plus a weekly limit
/// to weekly-only limits, so `five_hour` may be `null` or missing entirely.
struct UsageAPIResponse: Codable {
    let fiveHour: UsageLimitResponse?
    let sevenDay: UsageLimitResponse?
    let sevenDaySonnet: UsageLimitResponse?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

/// Individual usage limit response from API
struct UsageLimitResponse: Codable {
    let utilization: Double? // Percentage 0-100, can be null for inactive limits
    let resetsAt: String? // ISO8601 string, can be null

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Mapping error for API response conversion
enum MappingError: LocalizedError {
    case invalidDateFormat
    case missingCriticalField(field: String)

    var errorDescription: String? {
        switch self {
        case .invalidDateFormat:
            return "Server returned invalid date format"
        case .missingCriticalField(let field):
            return "Server response missing critical field: \(field)"
        }
    }
}

/// Extension to map API response to domain model
extension UsageAPIResponse {
    func toDomain() throws -> UsageData {
        // Session (5-hour) limit is optional; plans with weekly-only limits omit it.
        let sessionLimit = try fiveHour.flatMap { session -> UsageLimit? in
            try makeLimit(
                from: session,
                field: "fiveHour.resetsAt",
                fallback: Constants.Pacing.sessionWindow
            )
        }

        let reportedWeeklyLimit = try sevenDay.flatMap { weekly -> UsageLimit? in
            try makeLimit(
                from: weekly,
                field: "sevenDay.resetsAt",
                fallback: Constants.Pacing.weeklyWindow
            )
        }

        let weeklyLimit: UsageLimit
        if let reportedWeeklyLimit {
            weeklyLimit = reportedWeeklyLimit
        } else if sessionLimit != nil {
            // Session data present but no weekly data: treat weekly as unused.
            weeklyLimit = UsageLimit(
                utilization: 0,
                resetAt: Date().addingTimeInterval(Constants.Pacing.weeklyWindow)
            )
        } else {
            // No usable limit at all — nothing meaningful to display.
            throw MappingError.missingCriticalField(field: "sevenDay")
        }

        let sonnetLimit = try sevenDaySonnet.flatMap { sonnet -> UsageLimit? in
            try makeLimit(
                from: sonnet,
                field: "sevenDaySonnet.resetsAt",
                fallback: Constants.Pacing.weeklyWindow
            )
        }

        return UsageData(
            sessionUsage: sessionLimit,
            weeklyUsage: weeklyLimit,
            sonnetUsage: sonnetLimit,
            lastUpdated: Date()
        )
    }

    /// Builds a domain limit, or returns nil when the API reports the limit without a utilization value.
    private func makeLimit(
        from response: UsageLimitResponse,
        field: String,
        fallback: TimeInterval
    ) throws -> UsageLimit? {
        guard let utilization = response.utilization else {
            return nil
        }
        let resetDate = try parseResetDate(from: response.resetsAt, field: field, fallback: fallback)
        return UsageLimit(utilization: utilization, resetAt: resetDate)
    }

    private func parseResetDate(
        from rawValue: String?,
        field: String,
        fallback: TimeInterval
    ) throws -> Date {
        guard let rawValue else {
            return Date().addingTimeInterval(fallback)
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: rawValue) {
            return date
        }

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        if let date = plainFormatter.date(from: rawValue) {
            return date
        }

        throw MappingError.missingCriticalField(field: field)
    }
}
