# App Store 출시 점검

점검일: 2026-10-06 · 대상: native-ios의 실제 배포 앱

TestFlight 승인 사실은 사용자 제공 정보다. 이번 점검은 소스, 앱 번들, 연결된 iPhone과 Apple의 공개 심사 기준을 대상으로 했다. App Store Connect의 실제 제출 문구·연령 등급·개인정보 응답·스크린샷·심사 기록에는 접근하지 않았다. 만화 모드는 모든 사용자에게 동일한 직접 연결 절차를 제공한다. 심사자 전용 동작은 없다.

## 유지한 제품 동작

- **새 설치에는 어떤 서버도 등록하지 않는다.** 모든 서버는 사용자가 주소를 직접 입력하거나 선택한 백업·기존 iCloud 라이브러리에서 가져온다. 업데이트 시 기존 서버와 저장 데이터는 유지한다.
- 온보딩에서 주소 입력 또는 백업 가져오기를 선택한다. 나중에 설정할 수도 있으며, 빈 저장·탐색·태그 탭에서도 연결을 시작할 수 있다. 첫 서버를 추가하면 탐색 탭으로 이동한다.
- 알려진 주소는 서버 종류를 자동 선택하고 표시 이름은 주소로 채운다. 알 수 없는 주소는 사용자가 종류를 선택한다. 자동 선택은 주소 인식이며, 등록 전 서버 접속이나 콘텐츠 검증을 의미하지 않는다.
- 사용자 화면에서는 **만화 모드 / 이미지 모드**로 표시한다. 새 설치와 온보딩 완료 후에는 이미지 모드가 열린다.
- 연결되지 않은 만화 모드에 진입하면 라이선스 안내와 **주소 입력** 버튼을 표시한다. 이 상태에서는 만화 탐색 화면과 표지 다운로드를 시작하지 않는다. 기존에 직접 연결한 사용자는 연결 상태를 유지한다.
- 만화 모드의 실제 구현은 Hitomi 제공자를 사용한다. 이름 변경이 제공자나 콘텐츠 범위를 바꾸는 것은 아니므로 심사 메모에 실제 주소와 연결 경로를 공개한다.
- 사용자 지정 서버, 모든 수위 선택, 내장 브라우저와 기존 라이브러리 기능은 유지한다.
- [Mignori – Booru Browser의 현재 App Store 등록](https://apps.apple.com/ro/app/mignori-booru-browser/id1268897357)은 직접 추가한 서버 탐색과 로컬 컬렉션을 설명한다. 해당 지역 등급은 16+이며 제한 없는 웹 접근을 표시한다. 공개 등록 정보는 유사 제품의 존재를 뒷받침하지만, 최초 승인 시점이나 비공개 심사 사유를 증명하지는 않는다.

## 심사용 수동 연결 예시와 근거

심사 메모에 **https://safebooru.org**를 제공한다. 이 주소는 앱에 기본 등록되거나 추천 목록으로 표시되지 않으며, 심사자도 일반 사용자와 같은 입력 화면을 사용한다.

- [공식 API 문서](https://safebooru.org/index.php?page=help&topic=dapi): 게시물·태그 조회 API, JSON 응답 및 요청당 상한을 공개한다. 심사자가 아래 주소를 수동 등록하면 이 API로 탐색할 수 있다.
- [공식 이용약관 및 API 조건](https://safebooru.org/index.php?page=tos): 과도한 요청을 하지 않는 API 이용을 허용하며, API/CDN 이용 시 광고와 유료 장벽을 금지한다. 현재 앱에는 광고나 인앱 결제가 없다. 수익화 시 이 조건을 다시 검토해야 한다.
- 같은 약관은 개인적 이용과 미성년자 이용 금지를 명시하고, 게시물 정책은 SFW만 허용한다. 심사 메모에 이용 조건과 원문 링크를 제공한다. App Store 연령 등급은 서비스 자격 조건도 고려하여 운영자가 설정해야 한다.
- 이 문서는 API 접근 허용의 근거다. 개별 게시물의 저작권 전체를 앱에 양도하는 라이선스나 Apple의 승인 보증으로 해석하지 않는다. 제출일에 원문을 다시 확인하고, 요청 시 운영자의 별도 허가를 첨부한다.

## 보완한 항목

| 항목 | 변경 |
| --- | --- |
| 개인정보 안내 | 한국어·영어·일본어 방침을 번들에 포함하고, 설정·온보딩에서 오프라인으로 열 수 있게 했다. 공개 정책 URL도 제공한다. |
| 개인정보 API 선언 | 앱과 공유 확장에 UserDefaults의 앱 내부·동일 App Group 사용 사유를 선언했다. GRDB의 자체 manifest도 번들에서 확인한다. |
| 동기화 안내 | 온보딩에 기본 활성화 상태, 선택 가능 여부와 전송 범위를 설명하고 iCloud 토글을 제공한다. |
| 신고 | 두 모드의 상세정보에서 페이지 주소를 포함한 이메일 초안을 열 수 있다. 전송은 사용자가 직접 결정한다. 외부 원본 삭제는 사이트 신고도 필요하다고 설명한다. |
| 콘텐츠 제어 | Booru 상세정보에 게시물 숨기기와 작가 차단을 추가했다. 서버별 제외 규칙에서 해제할 수 있다. |
| 설정 | 화면 → 언어 → 탐색/연결 → 뷰어 → 검색 기록 → iCloud → 데이터 → 도움말 순서로 정리했다. 만화 모드 통계·가져오기·백업은 라이브러리 관리로 모았다. |
| 연락처 | NextLine 웹사이트는 정상 링크 색상으로 표시하며 앱 하단 배포사 표시는 제거했다. 사이트 HTTP 200과 연락처를 확인했다. |
| 분류 | 프로젝트의 건강·피트니스 분류를 엔터테인먼트로 수정했다. App Store Connect의 분류는 별도로 확인해야 한다. |
| 라이선스 | GRDB의 MIT 라이선스 및 저작권 고지를 앱에 포함했다. |
| 암호화 | OS 제공 HTTPS·Keychain·CryptoKit 사용을 확인하고 비면제 암호화 미사용 선언을 추가했다. |

## 제출 전에 운영자가 확인할 사항

1. **콘텐츠 범위:** 기본 서버 없이 직접 URL을 입력하는 제품 구조를 정확히 설명한다. 다만 [가이드라인 1.1.4·1.2](https://developer.apple.com/app-store/review/guidelines/#safety)는 실제 콘텐츠와 서비스 사용을 심사한다. 현재 앱의 전체 수위 선택과 Hitomi 기능까지 포함해 설명해야 하며, URL 직접 입력만으로 적용이 제외된다고 단정할 수 없다.
2. **신고 운영:** 이메일 경로와 로컬 차단은 구현했다. 신고를 확인하고 적시에 대응할 담당자, 외부 사이트에 대한 조치·연락 절차는 실제로 운영해야 한다. 클라이언트가 외부 서버의 게시물을 삭제할 권한은 없다.
3. **콘텐츠 권리:** 지원 사이트의 이용약관/API 접근 및 콘텐츠 표시 권한을 확인하고, Apple이 요청하면 근거를 제출해야 한다. 앱 소스만으로 권리 확보를 증명할 수 없다. [Apple의 제출 안내](https://developer.apple.com/app-store/review/)
4. **스토어 입력:** 기능에 맞는 카테고리와 웹 접근·사용자 생성 콘텐츠·노출 가능한 콘텐츠의 연령 질문을 사실대로 작성한다. 스크린샷과 소개문은 실제 기능을 보여주되 일반 공개에 적합한 소재를 사용한다. 기존 TestFlight 입력을 그대로 맞다고 가정하지 않는다.
5. **개인정보 응답:** NextLine 분석·광고 SDK는 없지만 사이트 요청, 쿠키, iCloud, 선택적 지원 문의가 존재한다. 외부 서비스와의 관계 및 실제 보관 방식을 확인한 뒤 App Store Connect에 답한다. 앱 manifest만으로 ‘수집 없음’ 응답이 확정되는 것은 아니다. [Apple 개인정보 표시 안내](https://developer.apple.com/app-store/app-privacy-details/)
6. **새 빌드:** 이번 보완은 기존 승인 빌드와 다르다. 새 빌드를 업로드하고 선택해야 한다. 이 작업에서 App Store 제출 버튼을 누르거나 심사 승인을 확인하지는 않았다.

## 검증 결과

- 빌드 5: 주소 검증 2개와 온보딩 UI 3개 테스트가 통과했다. 초기 입력에서 만화 사이트 연결, 이미지 서버와의 분리, 온보딩 후 이미지 모드, 가져오기 이동을 확인하고 한국어 화면을 캡처로 점검했다.

- 연결된 iPhone에서 관련 테스트 62개가 통과했다(별도 접속 조건이 필요한 7개 제외). 서버 미등록 상태, 주소 인식·등록, 기존 데이터 유지, 서버 삭제 후 재실행, 라이브러리 및 동기화를 검증했다. UI에서는 온보딩·건너뛰기·백업 진입, 주소만 입력한 첫 탐색, 서버 종류 수동 선택, 모드 전환 시 탐색 유지를 확인했다. 별도 서버나 실서비스 접속이 필요한 테스트는 기본 실행에서 제외한다.
- 두 모드의 설정과 NextLine 링크는 실기기 캡처로 확인했다. 서버·풀 아래에서 Booru 설정을 바로 조절하는 구조를 유지한다.
- 한국어·영어·일본어 번역 키의 일치와 개인정보 manifest 문법을 확인했다.
- 수동 연결 예시인 Safebooru API는 점검 시 HTTP 200과 general 등급의 응답을 반환했다. 다른 사용자 지정 서버의 가용성을 보장하는 결과는 아니다.
- 배포 준비 버전은 1.0.0, 빌드 번호는 5이다. App Store Connect용 IPA 내보내기에 성공했고, 앱·공유 확장의 배포 서명과 번들의 정책·라이선스·개인정보 선언을 확인했다. 업로드·심사 제출은 하지 않았다.

## 입력할 URL

- 지원 / 마케팅: https://nextline.work
- 개인정보처리방침: https://github.com/nextline-ai/Number-Memo/blob/main/docs/privacy-policy.md
- 지원 메일: contact@nextline.work

## Review Notes 초안

Number Memo is a native client for browsing user-selected websites and organizing local collections. A fresh installation contains no configured servers, bundled content, recommended-site list, or prefilled website address. Users explicitly enter addresses, import a backup they choose, or restore their existing library through optional iCloud sync. Existing configurations are preserved across updates. No Number Memo account is required.

To review image browsing using a public service:
1. On the first onboarding page, tap Enter Website Address.
2. Enter https://safebooru.org in Website Address. Leave Server Type on Automatic; the app displays Gelbooru. A custom name and account credentials are optional.
3. Tap Save. Continue through optional imports and the mode-switch tutorial, then tap Get Started. Image mode opens and the first configured server is available in Explore.
4. If setup was skipped, use Enter Website Address in Saved or Explore, or More > Servers > Add a Server. The same editor is used everywhere. To inspect other supported engines, manually enter a compatible site and select the type if it is not recognized.

Safebooru is a review example, not a bundled or recommended server. It publishes API documentation at https://safebooru.org/index.php?page=help&topic=dapi and terms at https://safebooru.org/index.php?page=tos. The terms permit API use without excessive requests, prohibit advertising/paywalls, and limit use to adults and personal use. Number Memo has neither advertising nor in-app purchases. These links document API access conditions, not a blanket license for every third-party post.

Supported image engines include Danbooru, Gelbooru, Old Gelbooru, and Moebooru. Address recognition selects an engine only; it does not create a server until the user saves. Account credentials, when supplied, are stored in Keychain for the relevant server. No credentials are required for the public review example above.

The user-facing Comics Mode uses the Hitomi provider. It is disconnected by default. During onboarding, tap Enter Website Address, enter hitomi.la (or https://hitomi.la/), and tap Save. The form recognizes it as Comics Mode and does not add it to the image-server list. Alternatively, after onboarding tap the book icon at the top, then Enter Website Address, enter hitomi.la, and tap Connect. The unconfigured comics-mode entry screen explains licensing and user responsibility for content access. This address enables only the implemented provider, not an arbitrary comics website. Once connected, Settings > Website Connection shows the configured address. All users have the same activation path. There is no review-only mode or remote feature switch. Onboarding always finishes in Image Mode, even if the user tried the comics icon in the tutorial.

The app includes native browsing and viewers, local folders/favorites, search history, configurable tag exclusions, optional embedded web browsing, image translation using Apple frameworks, and optional iCloud library sync. User-selected servers can return content of different ratings; the app includes rating controls. We do not represent all user-configured servers as Safebooru or as exclusively general-audience content.

Content details include a report path that opens a user-sent email draft. Booru details also offer local post hiding and artist blocking. These controls affect the app’s library and browsing; source websites retain control over their own posts.

Privacy Policy is accessible offline in Settings/More > Help & Privacy and from the first onboarding step. Sync starts enabled if iCloud Drive is available and can be disabled during onboarding or in settings. Support is available at contact@nextline.work.

## 참고 자료

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Encryption declaration](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
