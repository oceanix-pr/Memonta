import Foundation
import Testing
@testable import Memonta

/// 隐私政策版本化与正文披露的回归测试。
///
/// 这些断言不追求“文案好看”，只锁两件事：
/// 1. 改文本后必须能触发重新同意（版本语义不能退化）；
/// 2. 已核对过的合规披露不能被后续编辑悄悄删掉。
@Suite
struct PrivacyPolicyTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PrivacyPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private var policyText: String {
        MemontaPrivacyPolicy.sections
            .map { $0.title + "\n" + $0.body }
            .joined(separator: "\n\n")
    }

    // MARK: - 版本与重新同意

    @Test("全新安装需要同意")
    func freshInstallNeedsConsent() {
        #expect(MemontaPrivacyPolicy.needsConsent(accepted: false, storedVersion: nil))
        #expect(MemontaPrivacyPolicy.needsConsent(accepted: false, storedVersion: "2.0"))
    }

    @Test("只有旧布尔量、没有版本号的历史用户会重新收到同意页")
    func legacyAcceptanceWithoutVersionNeedsConsent() {
        #expect(MemontaPrivacyPolicy.needsConsent(accepted: true, storedVersion: nil))
        #expect(MemontaPrivacyPolicy.needsConsent(accepted: true, storedVersion: ""))
    }

    @Test("同主版本的次版本修订不重复打扰用户")
    func minorRevisionDoesNotReask() {
        #expect(!MemontaPrivacyPolicy.needsConsent(accepted: true, storedVersion: MemontaPrivacyPolicy.version))
        #expect(!MemontaPrivacyPolicy.needsConsent(accepted: true, storedVersion: MemontaPrivacyPolicy.majorVersion(of: MemontaPrivacyPolicy.version) + ".7"))
    }

    @Test("主版本升级必须重新同意")
    func majorRevisionNeedsConsent() {
        #expect(MemontaPrivacyPolicy.needsConsent(accepted: true, storedVersion: "1.9"))
        #expect(MemontaPrivacyPolicy.needsConsent(accepted: true, storedVersion: "2.0"))
    }

    @Test("主版本号解析")
    func majorVersionParsing() {
        #expect(MemontaPrivacyPolicy.majorVersion(of: "2.10.3") == "2")
        #expect(MemontaPrivacyPolicy.majorVersion(of: "2") == "2")
        #expect(MemontaPrivacyPolicy.majorVersion(of: "") == "")
    }

    @Test("接受后写入版本、时间与声纹单独同意")
    func acceptPersistsVersionTimestampAndVoiceprintConsent() {
        let defaults = makeDefaults()
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        MemontaPrivacyPolicy.accept(
            voiceprintConsent: true,
            at: date,
            defaults: defaults
        )

        #expect(defaults.bool(forKey: MemontaPrivacyPolicy.StorageKey.accepted))
        #expect(defaults.string(forKey: MemontaPrivacyPolicy.StorageKey.acceptedVersion)
                == MemontaPrivacyPolicy.version)
        #expect(MemontaPrivacyPolicy.acceptedDate(defaults: defaults) == date)
        #expect(MemontaPrivacyPolicy.voiceprintConsentGranted(defaults: defaults))
        #expect(!MemontaPrivacyPolicy.needsConsent(defaults: defaults))
    }

    @Test("接受时未显式给出声纹同意，不改动已有单独同意")
    func acceptWithoutVoiceprintArgumentKeepsExistingConsent() {
        let defaults = makeDefaults()
        MemontaPrivacyPolicy.setVoiceprintConsent(true, defaults: defaults)

        MemontaPrivacyPolicy.accept(defaults: defaults)

        #expect(MemontaPrivacyPolicy.voiceprintConsentGranted(defaults: defaults))
    }

    @Test("撤回总体同意会同时撤销声纹单独同意并清掉版本")
    func revokeClearsConsentState() {
        let defaults = makeDefaults()
        MemontaPrivacyPolicy.accept(voiceprintConsent: true, defaults: defaults)

        MemontaPrivacyPolicy.revoke(defaults: defaults)

        #expect(!defaults.bool(forKey: MemontaPrivacyPolicy.StorageKey.accepted))
        #expect(MemontaPrivacyPolicy.storedVersion(defaults: defaults) == nil)
        #expect(MemontaPrivacyPolicy.acceptedDate(defaults: defaults) == nil)
        #expect(!MemontaPrivacyPolicy.voiceprintConsentGranted(defaults: defaults))
        #expect(MemontaPrivacyPolicy.needsConsent(defaults: defaults))
    }

    // MARK: - 正文结构

    @Test("章节 id 唯一且正文非空")
    func sectionsAreWellFormed() {
        let ids = MemontaPrivacyPolicy.sections.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(MemontaPrivacyPolicy.sections.allSatisfy { !$0.title.isEmpty })
        #expect(MemontaPrivacyPolicy.sections.allSatisfy { !$0.body.isEmpty })
    }

    @Test("声纹是唯一需要单独同意的章节")
    func voiceprintIsTheOnlySeparateConsentSection() {
        let separate = MemontaPrivacyPolicy.sections.filter(\.requiresSeparateConsent)
        #expect(separate.count == 1)
        #expect(separate.first?.id == "voiceprint")
    }

    @Test("版本行同时包含版本号与生效日期")
    func versionLineIsVerifiable() {
        #expect(MemontaPrivacyPolicy.versionLine.contains(MemontaPrivacyPolicy.version))
        #expect(MemontaPrivacyPolicy.versionLine.contains(MemontaPrivacyPolicy.effectiveDate))
    }

    // MARK: - 合规披露

    @Test("正文覆盖已核对的关键披露")
    func policyCoversRequiredDisclosures() {
        let required = [
            "提醒事项",
            "辅助功能",
            "不会启动辅助功能检测",
            "iCloud",
            "Hugging Face",
            "模型下载",
            "自动更新",
            "不出售",
            "保留期限",
            "Voiceprints",
            "单独同意",
            "跨境",
            "未满 14 周岁",
            "18 周岁",
            "反馈信息",
            "个人信息保护法",
            "feedback@Memonta.app",
            "投诉"
        ]
        for keyword in required {
            #expect(policyText.contains(keyword), "隐私政策缺少关键披露：\(keyword)")
        }
    }

    @Test("不再出现“所有数据仅存储在本地”的绝对化表述")
    func absoluteLocalOnlyClaimIsGone() {
        #expect(!policyText.contains("所有数据仅存储在您的设备本地"))
        #expect(!policyText.contains("所有数据仅存储在您本机"))
    }
}
