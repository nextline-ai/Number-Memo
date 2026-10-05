# App Store 출시 점검

점검일: 2026-10-06 · 대상: native-ios의 실제 배포 앱

TestFlight 승인 사실은 사용자 제공 정보다. 이번 점검은 소스, 앱 번들, 연결된 iPhone과 Apple의 공개 심사 기준을 대상으로 했다. App Store Connect의 실제 제출 문구·연령 등급·개인정보 응답·스크린샷·심사 기록에는 접근하지 않았다. 기능 제한이나 심사자 전용 동작은 추가하지 않았다.

## 유지한 제품 동작

- 새 설치에 포함되는 Booru 서버는 Safebooru 하나다. 다른 서버는 사용자가 주소를 입력하거나 선택한 백업에서 가져온다.
- Hitomi는 온보딩 또는 웹사이트 연결 화면에서 주소를 직접 입력해야 활성화된다. 심사 메모에도 이 경로를 공개한다.
- 사용자 지정 서버, 모든 수위 선택, 내장 브라우저와 기존 라이브러리 기능은 유지한다.
- [Anime Boxes의 실제 App Store 등록](https://apps.apple.com/ca/app/anime-boxes/id525540312)에서도 사용자 지정 서버와 제외 규칙을 확인했다. 공개 목록으로 그 앱의 비공개 심사 사유까지 알 수는 없다.

## 보완한 항목

| 항목 | 변경 |
| --- | --- |
| 개인정보 안내 | 한국어·영어·일본어 방침을 번들에 포함하고, 설정·온보딩에서 오프라인으로 열 수 있게 했다. 공개 정책 URL도 제공한다. |
| 개인정보 API 선언 | 앱과 공유 확장에 UserDefaults의 앱 내부·동일 App Group 사용 사유를 선언했다. GRDB의 자체 manifest도 번들에서 확인한다. |
| 동기화 안내 | 온보딩에 기본 활성화 상태, 선택 가능 여부와 전송 범위를 설명하고 iCloud 토글을 제공한다. |
| 신고 | 두 모드의 상세정보에서 페이지 주소를 포함한 이메일 초안을 열 수 있다. 전송은 사용자가 직접 결정한다. 외부 원본 삭제는 사이트 신고도 필요하다고 설명한다. |
| 콘텐츠 제어 | Booru 상세정보에 게시물 숨기기와 작가 차단을 추가했다. 서버별 제외 규칙에서 해제할 수 있다. |
| 설정 | 화면 → 언어 → 탐색/연결 → 뷰어 → 검색 기록 → iCloud → 데이터 → 도움말 순서로 정리했다. Hitomi 통계·가져오기·백업은 라이브러리 관리로 모았다. |
| 연락처 | NextLine 웹사이트는 정상 링크 색상으로 표시하며 앱 하단 배포사 표시는 제거했다. 사이트 HTTP 200과 연락처를 확인했다. |
| 분류 | 프로젝트의 건강·피트니스 분류를 엔터테인먼트로 수정했다. App Store Connect의 분류는 별도로 확인해야 한다. |
| 라이선스 | GRDB의 MIT 라이선스 및 저작권 고지를 앱에 포함했다. |
| 암호화 | OS 제공 HTTPS·Keychain·CryptoKit 사용을 확인하고 비면제 암호화 미사용 선언을 추가했다. |

## 제출 전에 운영자가 확인할 사항

1. **콘텐츠 범위:** 기본 Safebooru와 직접 URL 입력은 명확히 설명할 수 있는 제품 구조다. 다만 [가이드라인 1.1.4·1.2](https://developer.apple.com/app-store/review/guidelines/#safety)는 실제 콘텐츠와 서비스 사용을 심사한다. 현재 앱의 전체 수위 선택과 Hitomi 기능까지 포함해 설명해야 하며, URL 직접 입력만으로 적용이 제외된다고 단정할 수 없다.
2. **신고 운영:** 이메일 경로와 로컬 차단은 구현했다. 신고를 확인하고 적시에 대응할 담당자, 외부 사이트에 대한 조치·연락 절차는 실제로 운영해야 한다. 클라이언트가 외부 서버의 게시물을 삭제할 권한은 없다.
3. **콘텐츠 권리:** 지원 사이트의 이용약관/API 접근 및 콘텐츠 표시 권한을 확인하고, Apple이 요청하면 근거를 제출해야 한다. 앱 소스만으로 권리 확보를 증명할 수 없다. [Apple의 제출 안내](https://developer.apple.com/app-store/review/)
4. **스토어 입력:** 기능에 맞는 카테고리와 웹 접근·사용자 생성 콘텐츠·노출 가능한 콘텐츠의 연령 질문을 사실대로 작성한다. 스크린샷과 소개문은 실제 기능을 보여주되 일반 공개에 적합한 소재를 사용한다. 기존 TestFlight 입력을 그대로 맞다고 가정하지 않는다.
5. **개인정보 응답:** NextLine 분석·광고 SDK는 없지만 사이트 요청, 쿠키, iCloud, 선택적 지원 문의가 존재한다. 외부 서비스와의 관계 및 실제 보관 방식을 확인한 뒤 App Store Connect에 답한다. 앱 manifest만으로 ‘수집 없음’ 응답이 확정되는 것은 아니다. [Apple 개인정보 표시 안내](https://developer.apple.com/app-store/app-privacy-details/)
6. **새 빌드:** 이번 보완은 기존 승인 빌드와 다르다. 새 빌드를 업로드하고 선택해야 한다. 이 작업에서 App Store 제출 버튼을 누르거나 심사 승인을 확인하지는 않았다.

## 검증 결과

- 연결된 iPhone에서 라이브러리·동기화, 개인정보 리소스, 설정 이동, 콘텐츠 신고·숨기기, 기본 온보딩 및 실제 Safebooru API·자동완성 테스트 25개가 통과했다.
- 두 모드의 설정과 NextLine 링크는 실기기 캡처로 확인했다. 서버·풀 아래에서 Booru 설정을 바로 조절하는 구조를 유지한다.
- 한국어·영어·일본어 번역 키의 일치와 개인정보 manifest 문법을 확인했다.
- 기본 Safebooru API는 점검 시 HTTP 200과 general 등급의 응답을 반환했다. 다른 사용자 지정 서버의 가용성을 보장하는 결과는 아니다.
- 배포 준비 버전은 1.0.0, 빌드 번호는 2다. App Store Connect용 IPA 내보내기에 성공했고, 앱·공유 확장의 배포 서명과 번들의 정책·라이선스·개인정보 선언을 확인했다. 업로드·심사 제출은 하지 않았다.

## 입력할 URL

- 지원 / 마케팅: https://nextline.work
- 개인정보처리방침: https://github.com/nextline-ai/Number-Memo/blob/main/docs/privacy-policy.md
- 지원 메일: contact@nextline.work

## Review Notes 초안

Number Memo is a native client for browsing user-selected websites and organizing local collections. A fresh installation includes Safebooru only. Users can continue onboarding without adding an address, then use the image mode to browse this server. No Number Memo account is required.

Other Booru servers are added explicitly through More > Servers or imported from a backup chosen by the user. Supported engines include Danbooru, Gelbooru, Old Gelbooru, and Moebooru. Account credentials are optional and are stored in Keychain for the relevant server.

The book mode uses the Hitomi provider. Entering hitomi.la during onboarding or under Settings > Website Connection enables this mode. The mode switch remains visible at the top of the app. Both modes and their activation paths are available to all users; there is no review-only mode or remote feature switch.

The app includes native browsing and viewers, local folders/favorites, search history, configurable tag exclusions, optional embedded web browsing, image translation using Apple frameworks, and optional iCloud library sync. User-selected servers can return content of different ratings; the app includes rating controls. We do not represent all user-configured servers as Safebooru or as exclusively general-audience content.

Content details include a report path that opens a user-sent email draft. Booru details also offer local post hiding and artist blocking. These controls affect the app’s library and browsing; source websites retain control over their own posts.

Privacy Policy is accessible offline in Settings/More > Help & Privacy and from the first onboarding step. Sync starts enabled if iCloud Drive is available and can be disabled during onboarding or in settings. Support is available at contact@nextline.work.

## 참고 자료

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Encryption declaration](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
