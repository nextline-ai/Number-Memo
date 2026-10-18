# 이미지 정렬과 룰렛 검색 시점

이미지 탐색, 챌린지 참고 이미지, 스마트 추천은 `BooruSort`의 서버별 지원 목록과 쿼리 생성기를 공유한다. 여러 서버를 함께 탐색할 때에는 공통으로 지원하는 정렬만 표시한다. 저장 폴더는 최신/점수순만 제공한다. 기존 스마트 추천의 `week` 저장값은 종전과 같은 전체 기간 점수순으로 해석한다.

| 서버 | 메뉴 | 요청 |
| --- | --- | --- |
| Danbooru | 점수 | `order:score` |
| Danbooru | 급상승 | `order:rank` |
| Danbooru | 즐겨찾기 | `order:favcount` |
| Danbooru | 추천수 | `order:upvotes` |
| Danbooru | 댓글 | `order:comment_count` |
| Danbooru / Moebooru | 최근 7일 / 30일 점수 | `date:>=YYYY-MM-DD order:score` |
| Gelbooru | 점수 | `sort:score:desc` |
| Moebooru | 점수 | `order:score` |

최근 기간은 UTC 날짜 기준이며 사용자가 직접 `date:` 또는 `age:` 조건을 입력했다면 그 조건을 우선한다. 정렬 선택은 기존 `order:`와 `sort:` 조건을 대체한다. 최신 선택에서는 사용자가 입력한 검색식을 그대로 유지한다.

Danbooru의 급상승은 서버가 산출하는 순서를 유지한다. 즐겨찾기/추천수/댓글 수는 응답의 해당 지표를 사용하며 점수로 다시 정렬하지 않는다. 기간이 제한된 검색의 빈 결과는 정상 결과로 처리한다. 지원하지 않는 정렬, 서버의 명시적 거부, 정렬 무시는 기존 피드를 보존하고 이전 정렬로 되돌린다. 임의 서버의 확장 기능을 지원한다고 가정하지 않는다. 구형 Gelbooru는 기존 호환 경로와 런타임 검증을 유지하며 현대 Gelbooru의 기능을 추가하지 않는다.

룰렛의 추첨 결과는 복원을 위해 먼저 저장하지만, 참고 이미지 피드는 수행/완료 가능 상태에서만 생성한다. 회전 중에는 검색, 이미지 요청, 검색어 노출을 시작하지 않는다. 릴 스트립도 첫 프레임에서 최종 결과가 노출되지 않도록 준비 후 표시한다.

## 스플래시

- 최초 실행: 정지 1.2초 + 슬라이드 1.8초.
- 앱 전환 후 복귀: 정지 0.6초 + 슬라이드 0.9초.
- 이동은 UIKit의 뷰 변환 애니메이션으로 처리하고 이미지 디코딩 결과를 재사용한다. 최초 스플래시는 SwiftUI가 배치하는 컨테이너를 고정하고 그 내부 화면만 위로 이동시켜, 레이아웃 갱신이 이동 방향을 바꾸지 않게 한다.
- 시작 시 동기화, 추천 리포트 준비, 검색 기록 정리는 스플래시가 끝난 뒤 시작한다.
- 복귀 도중 다시 나가면 진행 중 애니메이션과 제거 작업을 취소하고 가림 화면을 즉시 복구한다.
- 모션 줄이기에서는 이동 대신 짧은 페이드로 처리한다.

## 확인한 원자료

- [Danbooru 쿼리 구현](https://github.com/danbooru/danbooru/blob/master/app/logical/post_query_builder.rb), [게시물 정렬 구현](https://github.com/danbooru/danbooru/blob/master/app/models/post.rb)
- [Gelbooru 공식 검색 도움말](https://gelbooru.com/index.php?page=wiki&s=view&id=26263)
- [Moebooru 공식 검색 도움말 소스](https://github.com/moebooru/moebooru/blob/master/app/views/help/cheatsheet.en.html.erb)

네트워크 없는 fixture 테스트로 쿼리 구문, 지원 범위, 지표별 순서, 빈 결과, 이전 설정 호환, 검색 공개 시점, 복귀 중단 처리를 검증한다. 실제 서버별 네트워크 지연이나 실기기 프레임률은 이 테스트의 측정 대상이 아니다.
