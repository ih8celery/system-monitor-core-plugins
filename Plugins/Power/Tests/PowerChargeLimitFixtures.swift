import Foundation

/// /Library/Preferences/com.apple.powerd.charging.plist as captured on the development Mac on
/// 2026-10-14, base64 of the whole binary plist: one ChargeCtrlPolicy, reason
/// manualChargeLimit, soclimit 80.
enum PowerChargeLimitFixtures {
    static let captured = Data(base64Encoded: """
        YnBsaXN0MDDSAQIDBF8QD2Jvb3RTZXNzaW9uVVVJRFhwb2xpY2llc18QJDZBMkFCMkJGLUE4RUMtNDgwQy05NUQzLUFG
        NjM4QjI0QTE4OE8RAi5icGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYag
        XxAPTlNLZXllZEFyY2hpdmVy0QgJVHJvb3SAAagLDBIkJSkvM1UkbnVsbNINDg8RWk5TLm9iamVjdHNWJGNsYXNzoRCA
        AoAH2RMUFQ4WFxgZGhscHR4fICAfI1ZyZWFzb25Vb3duZXJYc29jbGltaXRVZHJhaW5adGVybWluYXRlZF5ub0NoYXJn
        ZVRvRnVsbF1pc0VuZE9mQ2hhcmdlVXRva2VugAMRAboQUIAGCQgICYAEXxARbWFudWFsQ2hhcmdlTGltaXTSJg4nKFxO
        Uy51dWlkYnl0ZXNPEBA+h8f0yEtCfJKVKuPjO73pgAXSKissLVokY2xhc3NuYW1lWCRjbGFzc2VzVk5TVVVJRKIsLlhO
        U09iamVjdNIqKzAxXxAQQ2hhcmdlQ3RybFBvbGljeaIyLl8QEENoYXJnZUN0cmxQb2xpY3nSKis0NV5OU011dGFibGVB
        cnJheaM0Ni5XTlNBcnJheQAIABEAGgAkACkAMgA3AEkATABRAFMAXABiAGcAcgB5AHsAfQB/AJIAmQCfAKgArgC5AMgA
        1gDcAN4A4QDjAOUA5gDnAOgA6QDrAP8BBAERASQBJgErATYBPwFGAUkBUgFXAWoBbQGAAYUBlAGYAAAAAAAAAgEAAAAA
        AAAANwAAAAAAAAAAAAAAAAAAAaAACAANAB8AKABPAAAAAAAAAgEAAAAAAAAABQAAAAAAAAAAAAAAAAAAAoE=
        """, options: .ignoreUnknownCharacters)!
}
