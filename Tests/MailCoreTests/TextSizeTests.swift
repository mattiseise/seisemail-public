import Foundation
import Testing
@testable import MailCore

@Suite struct TextSizeTests {
    @Test func defaultIsHundred() {
        #expect(TextSize.standard.percent == 100)
        #expect(TextSize.standard.factor == 1)
        #expect(TextSize.standard.isStandard)
    }

    @Test(arguments: [(0, 85), (-50, 85), (90, 85), (93, 100), (107, 100), (108, 115), (120, 125), (138, 150), (199, 200), (500, 200)])
    func snapsToNearestStep(input: Int, expected: Int) {
        #expect(TextSize(percent: input).percent == expected)
    }

    @Test func tieGoesToLargerStep() {
        #expect(TextSize(percent: 120).percent == 125)   // 115 and 125 are both 5 away
        #expect(TextSize(percent: 162).percent == 150)
        #expect(TextSize(percent: 163).percent == 175)
    }

    @Test func stepsUpAndDownAndStopsAtEnds() {
        var size = TextSize.standard
        var seen = [size.percent]
        while let next = size.larger { size = next; seen.append(size.percent) }
        #expect(seen == [100, 115, 125, 150, 175, 200])
        #expect(TextSize(percent: 200).larger == nil)
        #expect(TextSize(percent: 85).smaller == nil)
        #expect(TextSize.standard.smaller?.percent == 85)
    }

    @Test func scaledMetricsRoundToHalfPoints() {
        #expect(TextSize.standard.scaled(13) == 13)
        #expect(TextSize(percent: 115).scaled(13) == 15)      // 14.95
        #expect(TextSize(percent: 125).scaled(13) == 16.5)    // 16.25 → 16.5 (ties away from zero)
        #expect(TextSize(percent: 150).scaled(32) == 48)
    }

    @Test func metricRespectsItsCap() {
        #expect(TextSize(percent: 200).metric(200, cap: 1.5) == 300)
        #expect(TextSize(percent: 125).metric(200, cap: 1.5) == 250)
        #expect(TextSize(percent: 85).metric(200, cap: 1.5) == 170)
        #expect(TextSize(percent: 200).metric(32) == 64)
        #expect(TextSize(percent: 175).metric(28, cap: 1.25) == 35)
    }

    @Test func finnishLabels() {
        #expect(TextSize(percent: 125).label == "125 %")
        #expect(TextSize.standard.choiceLabel == "100 % (oletus)")
        #expect(TextSize(percent: 85).choiceLabel == "85 %")
        #expect(TextSize.all.map(\.percent) == TextSize.steps)
    }

    @Test func codableAsPlainInteger() throws {
        let data = try JSONEncoder().encode(TextSize(percent: 150))
        #expect(String(decoding: data, as: UTF8.self) == "150")
        #expect(try JSONDecoder().decode(TextSize.self, from: Data("400".utf8)).percent == 200)
    }
}
