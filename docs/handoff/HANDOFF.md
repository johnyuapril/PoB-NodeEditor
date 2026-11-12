# PoE2 빌드개발어시스트 인수인계 문서

작성일: 2026-11-12 · 작성: Claude (이전 계정 프로젝트 "poe2 빌드개발어시스트")
대상: 새 계정에서 같은 작업을 이어갈 사월아빠님과 새 프로젝트의 Claude

이 문서 하나만 읽으면 지금까지 무엇을 했고, 무엇이 어디 있고, 다음에 무엇을 하면 되는지 알 수 있게 썼어요. 맨 아래 **부록 A**에 새 프로젝트에 그대로 붙여 넣을 프로젝트 지시문과 시작 프롬프트가 있어요.

---

## 0. 먼저 해야 할 일 (이관 체크리스트)

새 계정은 이전 계정의 공유 폴더, 스레드, Claude Docs 문서, 아티팩트를 볼 수 없어요. 아래를 **이전 계정이 살아 있을 때** 해 두세요.

1. **공유 폴더 파일 내려받기** (이전 계정 프로젝트의 Library/파일 목록에서)
   - `handoff/HANDOFF.md` (이 문서)
   - `handoff/poe2-data-core.zip` : `poe2-data/`, `poe2-price/`, `downloads/` 전체를 묶은 것 (원본 HTML 묶음 제외)
   - (선택) `poe2-data/poe2db/raw_html_full.tar` (194MB, poe2db 원본 HTML. 추출기만 고쳐서 다시 뽑을 때 필요)
   - (선택) `poe2-data/poe2db/gem_html/` (467MB, 젬 페이지 원본 HTML. 대부분은 `gem_cards.json`으로 이미 추출됨)
   - `handoff/artifacts/` : 이전 계정 문서/페이지 사본
2. **새 프로젝트 만들기**: 새 계정에서 프로젝트를 만들고, 아래 부록 A의 지시문을 프로젝트 지시문에 넣으세요.
3. **파일 올리기**: 새 프로젝트 공유 폴더에 `poe2-data-core.zip`을 올리고, 첫 메시지에서 "압축을 /mnt/project-files/ 에 풀어줘"라고 하세요. 풀면 이전과 같은 `poe2-data/` 경로 구조가 돼요(이 문서의 경로가 그대로 맞아요).
   - 업로드 용량 제한에 걸리면 zip을 나눠 올리거나, `tags/entities_tagged.jsonl`(53MB)·`poe2db/kr_extract/pages.jsonl`(55MB)는 빼고 올려도 대부분의 작업은 돌아가요(재생성 스크립트 있음).
4. **GitHub 저장소 연결**: 새 프로젝트 설정의 Repositories에 `johnyuapril/pob-nodeeditor`를 추가하세요. 공개 저장소이고 노드 편집기 업데이트 채널이에요. 새 계정의 GitHub 연결이 같은 GitHub 계정(johnyuapril)이면 그대로 푸시할 수 있어요.
5. **클라우드 환경 네트워크 허용 도메인** (Project settings → Cloud environment → 환경 편집 → Network access → Allowed domains, "Allow package managers"는 체크 유지):
   - `poe2db.tw`, `cdn.poe2db.tw` (poe2db 수집)
   - `poe.ninja` (상위 빌드·PoB 코드)
   - `pobb.in`, `maxroll.gg`, `mobalytics.gg` (빌드 사이트, 아직 거의 안 씀)
   - `www.pathofexile.com` (래더·거래소. 단, 거래소 API는 클라우드 IP를 Cloudflare 403으로 막아서 PC에서 돌려야 함)
   - `github.com`, `raw.githubusercontent.com`, `codeload.github.com` (PoB 소스, 업데이트 채널)
   - `poemate.kr`는 허용해도 쓰지 않아요 (robots.txt가 AI 수집기를 명시적으로 차단)
6. **이전 계정 문서 사본 확인**: `handoff/artifacts/`에 아래가 들어 있어요. 원본 링크는 이전 계정에서만 열려요.
   - `숨겨진_연결성_1차_탐색.md` : 원본 Docs 전체 내보내기 (1~17절)
   - `젬링_화염파_메커니즘_해석_요약.md` : 요약본 (원본 전체가 필요하면 이전 계정에서 문서 → 내보내기 → Markdown)
   - 조건 지도 페이지: `poe2-data/conditions/explorer/index.html` (+ `data.json`)
   - poe.ninja 빌드 구간표 페이지: `poe2-data/ninja_builds/tiers_page/index.html` (+ `tiers.json`)
7. **사용자가 올린 스크린샷**: `uploads/hearth/` 이미지 12장(노드 편집기 UI 참고 그림, 블루프린트 스타일 예시, 치명타 시 시전 툴팁 등). 필요하면 함께 내려받으세요.

참고: 이전 프로젝트는 **Claude 메모리가 꺼져 있었어요**. 그래서 결정사항은 이 문서와 `poe2-data/semantics/PRINCIPLES.md`에만 남아 있어요.

---

## 1. 프로젝트 목표

> "poe2에서 최고의 성능을 내는 빌드를 만들고 싶어. PoB를 분석해서 데미지 계산 공식을 파악하고 poe2db의 내용과 접목해서 가장 강한 성능을 내는 빌드를 만드는 게 목적이야."

대화를 거치며 목표가 이렇게 구체화됐어요.
- 상위 빌드 개선이 아니라, **고유템·혈통젬·보조젬·노드·주얼 등 가용 자원을 총동원해 새로운 시너지 빌드를 발견**하는 것.
- 핵심은 "피해 몇 % 상승"이 아니라 **A→B→C→A처럼 거미줄로 맞물려 폭발적으로 증폭되는 순환 구조**를 찾는 것.
- 그러려면 GGG 공식 문장(스킬·보조젬·아이템·노드 설명)을 **문장 단위로 정확히, 그리고 다각적으로** 해석해야 함.
- 최종 그림: 공개 게임 데이터로부터 인간이 생각 못 한 조합을 찾아내고 왜 작동하는지 증명하는 **빌드 발견 엔진** + 그 결과를 설명·조작하는 **노드 편집기**.

게임/리그 기준: PoE2 0.5.x, 리그 **Forbidden Rites** (사용자가 0.5.5 시즌이라고 부름). PoB PoE2 v0.23.1 (커밋 bb52d6b, 2026-10-01).

---

## 2. 사용자의 작업 원칙과 선호 (꼭 지킬 것)

`poe2-data/semantics/PRINCIPLES.md`에 일부가 있고, 나머지는 대화에서 나온 지시예요.

1. **속도보다 정확성.** 오래 걸려도 교차 검증으로 정확한 메커니즘을 이해하는 게 최우선.
2. **단어로 분류하지 말 것.** "치명타", "발동" 같은 단어 하나로 연결하면 틀림. 위세당 에너지, 상태 이상 한계치 비율, 퀄리티 추가 효과까지 문장 전체를 해석.
3. **교차 검증**: (1) PoB 해석과 대조 (2) PoB로 켜고 끄며 수치 확인 (3) 공식 문장/키워드 링크와 대조 (4) 애매하면 사용자 검토표. 데이터로 확인 안 되면 **웹 검색으로 확인**(예: 화염술의 맹약 자기 피해가 명중인지).
4. **문구를 다각적으로 해석해 가능성을 열어 둘 것.** 한 가지 뜻으로 읽고 "안 된다"고 닫지 말 것(기름 지대 사건). 확정 / 정황 있음 / 미확인으로 구분.
5. **조건부 효과는 "조건이 충족되면 무슨 효과가 나는지" 파악 → 그 조건을 충족시키는 방법을 찾는 방향.**
6. **빌드가 어떤 메커니즘으로 딜이 나오는지 먼저 파악.** 단순 DPS 표기를 올리는 최적화는 의미 없음(권능 충전 빌드에서 충전 노드를 빼 버린 사건).
7. **문제 해결형 탐색**이 잘 맞음: "젬링 품질로 화염파 증폭이 엄청난데, 이걸 다른 데 쓸 수 없나?"처럼 자산에서 출발.
8. **숨겨진 연결은 Claude가 찾아야 함.** 기존 빌드 유형(전이 등)에 한정하면 남의 빌드를 따라가는 것뿐.
9. **모든 데이터는 빠짐없이 전부 수집·분석.** 필요한 것만 받지 말 것(추출 누락으로 연결이 꼬였던 사건).
10. **한 방형 빌드는 DPS가 아니라 "한 방 총량 + 재준비 시간"으로 평가.** 지속형은 초당 피해 + 유지 조건.
11. **현실 제약 반영**: 정신력, 보조 칸 5개, 능력치 요구, 무기 세트 패시브 규칙, 같은 유형 보조젬 중복 금지, 지금 얻을 수 있는 아이템인지.
12. **모든 용어는 한국어 클라이언트 공식 표기**(poe2db 한글판 기준).
13. **말 안 해도 계속 진행.** 작업이 끝나면 다음 작업을 바로 걸어 두고, 멈춘 게 있으면 먼저 말할 것. 진행 상황을 물으면 솔직하게.
14. 사용자는 Windows PC(`D:\AI\POE2` 등 폴더)에서 PoB와 노드 편집기를 씀. 모바일 앱에서는 환경 설정 편집이 안 됨.
15. 다른 AI의 피드백을 붙여 넣고 "의견을 묻는 것"일 때가 있음. 그대로 따르지 말고 동의/반대 의견을 먼저.

---

## 3. 스레드별 대화 요약 (시간순)

### 3-1. 두 사이트 데이터 전체 수집하기 (11/04, 완료)
- 요청: poe2.myplay.fyi와 poe2db.tw를 REA/Ghidra로 분석해서 모든 데이터 수집.
- 결론: myplay는 **PoB2KR**(브라우저용 한글판 PoB2, 0.23.1 기반)이라 원본인 PathOfBuilding-PoE2에서 데이터를 직접 추출하는 게 맞음. Ghidra 불필요(PoB는 Lua 소스).
- PoB2 원본에서 게임 데이터 전체를 JSON으로 추출 → `poe2-data/pob_json/` (젬 966, 베이스 1769, 유니크 435, 모드 풀 약 9천, 트리 0.1~0.5, ModCache 1만).
- 네트워크 차단 때문에 새 환경에서 실제 수집은 다음 스레드로 넘김. 사용자가 myplay 대신 poemate.kr을 허용.

### 3-2. 두 사이트 실제 데이터 수집 → "수집 데이터 태그와 연관성 찾기" (11/04~05)
- poe2db.tw 한글판 **17,396페이지 전부** + 영문판 핵심 140페이지 수집(2시간 실행 제한으로 여러 번 이어받음, 실패 273은 사이트 깨진 링크).
- poemate.kr은 robots.txt가 ClaudeBot 등 AI 수집기를 `Disallow: /`로 막아서 **수집 안 함**(결정).
- 결과: `poe2db/merged/` (모드 풀 12,778, 유니크 468, 한영 이름표 17,785, PoB 젬 966 중 964 한글 매칭), `passive_tree/`(노드 5,152 한영).
- 이어서 사용자 요청으로 **모든 자료에 태그 부여 + 연관성**: 자료 28,129개, 개념 태그 2,427종, 단어 태그 14,802종 → `poe2-data/tags/`.
- "A와 B가 C를 발동하고 C가 D를 올려 다시 A를 증폭" 같은 **거미줄 순환** 요청 → 방향 연결 6,458개, 순환 고리 214개.
- **실제 빌드 연결 가능 테스트**: 경로·전직·슬롯·의미 검사 후 확실한 고리 3개(환기 실행자 + 기원 메타 젬 축). `tags/build_test_report.md`.
- 한계: 규칙 기반 판별이라 오탐 많음(상위 15개 중 11개 오탐). 이 스레드는 review_ready 상태로 남아 있음.

### 3-3. 레어 아이템 가격 산출기 만들기 (11/04, 완료)
- 방법 3(거래소 매물로 직접 모델링) 선택 → `poe2-price/` (CLI: `tiers`, `rates`, `collect`, `train`, `estimate`, LightGBM).
- 거래소 API는 클라우드 IP를 Cloudflare 403으로 차단 → **사용자 PC에서 collect를 돌리고 데이터를 올려 학습**하는 방식으로 결정. 우회는 하지 않음.
- 사용자 지시: **divine 거래 매물만**, 가격 구간 **21~50 / 51~100 / 101~200 / 200~500 / 500~1000 / 1000div 이상** (1~20div는 버림). 학습도 21div 미만 제외.
- 리그 "Forbidden Rites", rates 결과 1 divine ≈ 580 exalted, 1 chaos ≈ 90 exalted (11/04).
- 버그 수정: annul/aug 매물 없을 때 오류.
- **미완료**: 사용자가 PC에서 collect한 `data/rates.json`, `data/raw/*.jsonl`을 아직 올리지 않음 → 실제 학습·검증 미수행. 한글 클라이언트 아이템 텍스트 매핑도 미구현(영문 기준).
- 배포본: `downloads/poe2-price.zip` (poe2-price + 티어 판별용 poe2-data 일부 포함).

### 3-4. 숨겨진 빌드 연결성 찾기 (원래 이름 "PoB를 AI 빌드 계산기로 만들기", 11/05~11/09) — 핵심 스레드
아래 4~8장에 결과물별로 자세히 정리. 흐름만 요약하면:
1. **PoB 헤드리스 계산기** 완성 (`pob_calc/`). PoB 자체 테스트 값(11.8/17.5 DPS)과 일치, poe.ninja 수치와도 일치.
2. 시너지 고리 3개 측정 → 최고 +14%. 사용자: "전혀 좋은 빌드가 아니다, 다른 빌더 빌드부터 학습하라."
3. **poe.ninja 상위 빌드 541개** 수집·재계산 → `ninja_builds/build_rules.md`.
4. 사용자: "상위 빌드 개선이 아니라 모든 자원을 총동원한 새 빌드." → **분해 실험(ablation)** + **3단계 자동 빌드 탐색** + **희귀 아이템 옵션 파워**.
5. 사용자 아이디어: **노드 연결 방식(블루프린트)**으로 연결성 구현 + 직접 조작 + DPS/EHP 즉시 표시 → **PoB 노드 편집기**(Windows, v2~v24) + GitHub 업데이트 채널.
6. 연결이 단어 규칙이라 계속 꼬임 → **GGG 공식 문장 전수 해석·교차 검증**(`semantics/`), poe2db 한영 전체 재수집 시작.
7. 최적화가 메커니즘을 모르고 DPS 표기만 올림 → **메커니즘 분석 탭**, **조건 지도**(조건 723개, 연관 482개).
8. **젬링 화염파** 빌드를 우리 해석만으로 파악 → 성공(고급 마석학 = 단계당 점화 증폭). 기름 지대 해석을 두고 사용자 교정.
9. **숨겨진 연결성 탐색**(문제 해결형, 역방향, 약점 역이용, 순환) 1~17절. 사람이 찾은 조합 재발견으로 방법은 검증, 확실한 신규 대박 조합은 아직 없음.
10. 11/09 마지막: "자동 점검은 여기서 멈출게요. 이어서 **진화형 다양성 탐색**을 할지, 다른 방향으로 갈지 말씀해 주세요." → **사용자 답 대기 상태로 끝남.**

### 3-5. 이 스레드 (11/12): 다른 계정 이관용 정리

---

## 4. 저장소와 노드 편집기

### 저장소: `johnyuapril/pob-nodeeditor` (GitHub 표시명 PoB-NodeEditor, 공개)
- 용도: 사용자 PC 노드 편집기의 **업데이트 채널**. 편집기의 "업데이트" 버튼이 `raw.githubusercontent.com/.../main/pob_calc/web/version.json`을 읽고, 버전이 더 높으면 main을 zip으로 받아 적용 후 재시작.
- 구조: `README.txt`, `update.ps1`, `pob_calc/{driver.lua, serve.lua, http.lua, catalog.lua, mechdetail.lua, optimizer.lua, shim/, web/}`
- 브랜치(2026-11-12 기준):
  - `main` : 최신 **v24** (d777dbf "v24: add top stage-3 build search results as examples")
  - `claude/project-thread-jgmo9z` : main과 같은 커밋 + 이 인수인계 문서(`docs/HANDOFF.md`) 커밋
  - 열린/닫힌 PR 없음. 지금까지 편집기 릴리스는 main에 직접 푸시했음.
- 릴리스 방법(`poe2-data/node_editor/RELEASE.md`):
  1. `poe2-data/pob_calc/`의 파일 수정 (driver.lua, serve.lua, http.lua, shim/, web/ 등)
  2. `pob_calc/web/version.json`의 `version`(정수)과 `notes` 올리기 (현재 24)
  3. 저장소 클론의 `pob_calc/`로 복사 → 커밋 → main 푸시
  4. 새 설치용 전체 zip(`node_editor/PoB-NodeEditor.zip`)도 갱신
  - start.bat은 업데이트로 교체되지 않음(실행 중인 배치 파일). update.ps1이 codeload zip을 받아 robocopy, 서버가 종료 코드 3으로 끝나면 start.bat 루프가 재시작.
- 새 설치: `poe2-data/node_editor/PoB-NodeEditor.zip`을 영문 경로(예: `C:\PoBEditor`)에 풀고 `start.bat` (bin\에 Windows LuaJIT, pob\에 PoB PoE2 소스 포함).

### 편집기 버전 이력 (주요 기능)
| 버전 | 내용 |
|---|---|
| v1~v2 | 카드(입력=왼쪽 점, 출력=오른쪽 점) + 연결선, 선 끊기/잇기 → PoB 재계산, 순환 고리 강조, PoB 코드 만들기, 한국어 용어, poe.ninja 예시 14개(PoB와 오차 0%), 블루프린트 디자인, 업데이트 버튼 |
| v3~v5 | 스킬 카드 보조 칸 5개, "보조받는 스킬 한정" 조건 구분(일촉즉발), 치명타 시 시전 오연결 수정 |
| v6~v8 | 연결 규칙을 PoB 데이터 기반으로 재작성, **전역 효과** 카드(치명타 확률 등은 여기로만), 추정 연결 점선, 메타 젬 발동 연결 |
| v9 | GGG 원문 해석 기반 연결 (요소 1,897, 포트 224) |
| v10~v13 | 보조젬을 스킬 카드 안으로, 빈 칸 클릭 시 장착 가능한 보조젬 + "피해 +38.6%" 미리보기, 젬 툴팁, 장비 끄기, 전역 선 제거·선 기본 흐림·선택 경로 강조, **카드별 기여도 %**, 열 접기 |
| v14~v16 | **고리 찾기** 탭, 현실 제약(정신력·칸·능력치), **최적화** 탭(보조젬·패시브 교체, 되돌리기) |
| v17~v19 | 변경 강조, 연결 기반 자동 배치, 스킬 포커스, 미충족 조건 경고, DPS 기여 분해, **패시브 트리 화면**(poe2db 기능 + PoB 미리보기), 최적화 전/후 비교·검증 6가지, 의존성 추적(할당 관계 vs 계산 관계 구분) |
| v20~v21 | 무기 세트 패시브 규칙(24포인트를 세트 1·2가 공유, 최대 48개, 일반 포인트 풀의 일부) 반영, **주력 무기 세트 선택** |
| v22~v23 | **메커니즘 탭**(조건 하나씩 꺼서 엔진 파악, 미충족 조건 → 충족 수단), PoB 계산 줄 단위 피해 공식 분해, 스택 곡선, 확장 후보 |
| v24 | 자동 탐색 3단계 상위 5개를 예시 빌드로 추가 + 조건 카탈로그 op |

### 알려진 편집기 이슈/미구현
- poe.ninja 코드에는 **스킬별 무기 세트 배정**이 없어 정신력이 −80~−120으로 보임(계산 오류 아님). 카드에 세트 1/2 선택 기능은 제안만 함.
- poe.ninja 코드에는 **화염파 같은 단계형 스킬의 단계 수**가 없어 PoB가 약 25배 낮게 계산 → 최대 단계 기본 설정 필요(미구현).
- 희귀 아이템 카드 일부, PoB 설정에 없는 연결(주입, 소환수 등)은 끊어도 숫자 불변.
- 고리 찾기는 "하나 더하기"만. "둘을 함께 더해야 생기는 고리", "새 스킬 자체 DPS"는 미구현.
- 빌드 설계 모드 / 메커니즘 디버그 모드 분리, 잠금·변경 허용·제외 속성(자동 탐색용)은 제안 단계.

---

## 5. PoB 헤드리스 계산기 (`poe2-data/pob_calc/`)

- PoB PoE2의 Lua 계산 엔진을 화면 없이 실행. 빌드 코드 또는 spec(직업·노드·젬·아이템) → DPS·EHP 등 JSON. variants(하나씩 바꿔 비교), nodePower(노드 후보 순위), customMods, config, export(PoB 코드).
- 준비: `bash poe2-data/pob_calc/setup.sh` → PoB 소스를 `~/pob2`에, PoB 전용 LuaJIT(2460b3ff 커밋, `+=`·`?.`·`continue` 문법 지원)를 `~/luajit-pob`에 설치. `export POB_DIR=~/pob2`. 프로젝트 폴더는 noexec라 바이너리를 홈으로 복사.
- 사용: `python3 pob_calc.py calc --code <코드>`, `python3 pob_calc.py run request.json`, `decode`/`encode`. 한 번 4~5초.
- 상주 모드 서버: `serve.lua` (빌드 로드 0.8초, 변경 0.2~0.3초) — 노드 편집기의 백엔드.
- 주의:
  - **PoB는 기원(Invocation)/치명타 시 시전의 에너지→발동 빈도를 계산하지 않음.** 메타 젬 빌드 DPS는 별도 모델 필요.
  - 고통의 조율 빌드는 PoB가 항상 낮은 생명력으로 계산 → 생명력 가득 찬 동안 실제 DPS는 28~30% 낮음.
  - 살을 에는 서리 II 같은 "동결 소모 한 방"을 PoB가 매 타 적용해 부풀림.
  - PoB 버그 목록: `semantics/POB_BUGS.md` (철의 손아귀/철의 의지 효과 뒤바뀜, 드루이드:/사냥꾼: 시작점 줄 미해석 등)
- 메모리가 작은 환경에서는 PoB 계산을 병렬로 많이 돌리면 OOM. 공통 검증기 하나가 줄 세워 처리하는 구조 권장.

---

## 6. 주요 결과와 결론

### 상위 빌드 541개 학습 (`ninja_builds/build_rules.md`)
- 오래 사는 상위 빌드: DPS 약 40만, EHP 약 4만, 원소 저항 75% 3종, 카오스 저항 약 50%, 정신력 약 220.
- 공통: 치명타 스택, ES 쪽 방어(고통의 조율·MoM·CI), 주력 스킬 보조 5개, Mageblood·Kalandra's Touch, 이름 붙은(혈통) 보조젬(Rakiata's Flow 등).
- 분해: 1위 Twister 빌드는 Rakiata's Flow 하나만 빼도 DPS −60%. Charge Regulation + Garukhan's Resolve 함께일 때 +14% 시너지.

### 희귀 아이템 옵션 파워 (`ninja_builds/rare_mod_power.md`)
- DPS 1위 옵션: "+주문 스킬 레벨" 한 줄이 DPS 약 37%. 공격 빌드는 무기 물리 % 증가 29%, 물리 추가 21%.
- 주얼: "반경 내 노터블이 치명타 피해 보너스 부여" 한 줄당 12~15%.
- 방어: 저항 한 줄이 EHP 12~14%.

### 3단계 자동 빌드 탐색 (`build_search/`)
- 1단계 스킬 173개 → 2단계 상위 15 스킬 × 전직 23 (345) → 3단계 상위 32개 정밀 최적화(EHP 약 4만 기준).
- 최종 상위: 사술 폭발 인퍼널리스트 880만 / 불씨 일제 사격 블러드 메이지 864만 / 번개 차원 이동 인퍼널리스트 692만 / 화염 폭풍 블러드 메이지 551만 / 신속한 사격 젬링 리저네어 549만 (모두 EHP 약 4만). 편집기 예시 "[자동 탐색]"으로 들어감.
- 한계: ninja 상위(2천만~1억+)보다 낮음. DPS 순위라 한 방형 평가 기준 미반영. "출발점" 정도로 볼 것.

### 공식 문장 해석·검증 (`semantics/`)
- 젬 822개 카드 수집, 젬 문장 템플릿 2,301개 해석 + 교차 검증. 패시브·고유 문장 2,438개 템플릿 전부 해석, PoB 해석과 표시 불일치 0.
- 구 규칙 버그 목록 `RULE_BUGS.md` (예: "동결 축적을 가할 수 없음"을 동결 생산으로, "aftershock"을 "shock"으로 오매칭, "막기 확률 증가"를 막기 생산으로).
- 스키마: `SCHEMA.md`, 예시: `example_cast_on_critical.md`.

### 조건 지도 (`conditions/`)
- 노드·고유·아이템 옵션·룬·젬 4,983개 요소에서 조건 723개, 조건부 효과 줄 3,565개, 조건 간 연결 482개(켜 주는 관계·같은 카드·엔진 파생·동시 요구·반대 조건, 3단계 연쇄).
- 발견: "최근 적 처치"가 가장 많은 조건을 켜 줌(맹공·격노·권능 충전·발동). 207개 조건은 만드는 카드 없이 행동/상황으로만 충족.
- 각 줄에 "PoB 해석" / "문구 분석(추정)" 표시.

### 젬링 화염파 해석 (`handoff/artifacts/젬링_화염파_메커니즘_해석_요약.md`)
- 우리 도구만으로 핵심(고급 마석학 → 젬 퀄리티가 단계당 점화 88% 증폭) 파악 성공. 1단계 97만 → 10단계 2,379만.
- 기름 지대: 처음에 "지대 점화는 기름 유탄 기준 고정값"이라고 단정했다가, 사용자 교정으로 **"화염파의 거대 점화가 기름 지대로 옮겨 붙어 확산"이 정황상 성립**으로 수정. 이 사건이 "다각적 해석" 원칙의 계기.

### 숨겨진 연결성 탐색 (`handoff/artifacts/숨겨진_연결성_1차_탐색.md`, `hidden_links/`)
주요 후보와 판정:
| # | 후보 | 판정 |
|---|---|---|
| 1 | 서리불꽃 폭발 × 화염파(점화 지속 초기화) | 보스가 1초에 녹으면 의미 적음 → "보험" 수준 |
| 2 | 화염 기둥 × 큰 점화(남은 피해 25% 광역) | 유망, 미측정 |
| 3 | 베이라의 비통 × 와류 × 돌개바람 | 미확인 |
| 4 | 적검단 깃발 × 원소 상태 이상 시 시전(발동 2배) | 미측정 |
| 5 | 신성한 불꽃 × 도리아니의 프로토타입 | 사람이 찾은 조합 재발견(방법 검증) |
| 6 | 젬링 품질: 신들의 망치(재발견), **번개 도관(품질 50% → 추가 번개 +10)**, 얼음 폭발 | 번개 도관 보류(14절) |
| 6-1 | 급성장 II로 화염파 0.7초 더 채널 → 40% 증폭 | 상위 4명 중 1명만 사용 |
| 6-2 | 얼음 폭발 품질 50% "주입 소모로 간주" + 힘의 주입 + 강화하는 주입 | 연쇄 성립, 미측정 |
| 7 | 데드아이 나선 사격 공세 "충전 이득 2배" 100% | 사용자 0명, 미측정 |
| 8 | 가장 깊은 탑 "접근한 적 낮은 생명력 간주" | 지난 리그 아이템 + 이득<손해 → 기각 |
| 9 | 웃는 번제 + 베이라의 비통 + 베렉의 길 | 수치 작음 → 기각 |
| 10 | 호신부 자기 발동 (화염술의 맹약 자기 피해 = 명중 → 나마후의 선택받은 자) | 웹 검색상 가능성 높음, 인퍼널리스트 사용 0 |
| 11 | 철결속 활(방어도→막기→피해, 화살 복귀) | PoB 검증 DPS −68~−79% → 딜 기각, EHP +62% |
| 13 | 역방향: 화염 벽 → 번제 → 얼음 화살 (+17~24%), 치명타 시 시전으로 화염 벽 자동화 | 유망, 정신력 100 |
| 15~17 | 약점 역이용, 2단/3단 순환 | 큰 후보 없음, 치명타 시 시전+환기 실행자 +5% |

데이터 정정 기록: 호신부 사용률은 요약 파일에만 없고 원본에 있음(베이라의 비통 120명, 도끼의 추락 186명, 나마후 7명). 같은 유형 보조젬 두 개 동시 사용은 상위 541명 스킬 묶음 6,423개 중 0 → 금지 규칙 확정.

### 개발 방향 합의 (11/07)
- 사용자가 다른 AI의 "신개념 빌드 발견 엔진" 설계(규칙 기반 추론 + 지식 그래프 + 제약 탐색 + 역방향 조건 추론, 20가지 다중 발견 엔진)를 공유하고 의견을 물음.
- Claude 의견(사용자 동의):
  1. 영어 문장 LLM 해석보다 **PoB 데이터(스킬 타입, 스탯 ID)를 우선**, 문장 해석은 그게 없는 곳에만.
  2. 전투 시뮬레이터를 새로 만들지 말고 **PoB 계산기 재사용**, PoB가 못 하는 건 "규칙상 성립"으로 표시.
  3. 새로움은 **상위 541명 실제 사용 여부**로 판정.
  4. 엔진마다 최소 탐색 예산 보장, 결과는 메커니즘 계열별 보존(다양성).
  5. 공통 후보 형식: 출처·조건·검증 단계(**규칙상 성립 / 계산상 유망 / 게임 내 검증**) + 공통 PoB 검증 대기열.
  6. 첫 엔진 4개: **역방향 조건 추론, 약점 역이용, 순환 구조, 진화형 다양성(MAP-Elites 등)**. 앞의 세 개는 1차 실행 완료, **진화형 다양성은 미착수**.
- 자동 검증 도구 `tools/verify_candidate.py`: 스킬·무기·전직으로 ninja 기준 빌드를 고르고 아이템/노드를 바꿔 넣어 DPS·EHP 차이 측정. 앞으로 모든 후보는 이 도구로 숫자를 뽑고 보고하기로 함.

---

## 7. 미완료 작업 (다음에 할 일)

우선순위 순:
1. **(사용자 결정 대기)** 숨겨진 연결성 다음 단계: 진화형 다양성 탐색으로 갈지, 다른 방향으로 갈지. 11/09 마지막 질문에 답 없음.
2. 유망 후보 PoB 측정: 화염 기둥 × 화염파 점화, 얼음 폭발 주입 연쇄, 데드아이 충전 이득 2배, 적검단 깃발 × 원소 상태 이상 시 시전, 화염 벽(치명타 시 시전) → 번제 → 얼음 화살의 점화 유지율.
3. 공통 후보 형식 + PoB 검증 대기열 + 다중 엔진 플러그인 구조 구현.
4. 편집기: 단계형 스킬 최대 단계 기본값, 스킬별 무기 세트 지정, "둘 더하기" 고리 찾기, 새 스킬 자체 DPS, 한 방형 평가 지표.
5. 메타 젬(기원·치명타 시 시전) 에너지→발동 빈도 모델.
6. poe2db 한영 **전체 재수집** 완료 + 전체 추출기(`tools/poe2db_full_extract.py`) 실행. 11/07 기준 한·영 각 약 8,700쪽, 대기열 약 7,500쪽 남음. 환경이 자주 재시작돼서 계속 끊김. 현재 원본 묶음은 `poe2db/raw_html_full.tar`.
   - 젬 카드 822개는 이미 완료(`poe2db/gem_cards.json`, `gem_html/`).
7. 가격 산출기: 사용자 PC 수집 데이터 업로드 → 학습·검증, 한글 클라이언트 매핑.
8. "수집 데이터 태그와 연관성 찾기" 스레드는 review_ready로 남아 있었음(규칙 기반 태그 결과는 이후 semantics/조건 지도로 대체됨).

---

## 8. 공유 폴더 파일 지도 (`/mnt/project-files/`)

| 경로 | 크기 | 의미 |
|---|---|---|
| `handoff/` | | 이 인수인계 문서, 핵심 데이터 zip, 이전 계정 문서 사본 |
| `downloads/poe2-price.zip` | 0.3MB | 가격 산출기 PC 배포본 |
| `poe2-price/` | | 가격 산출기 소스 (cli.py, poe2price/, tests/) |
| `uploads/hearth/` | | 사용자가 올린 스크린샷 12장 |
| `poe2-data/README.md` | | 수집 데이터 설명 (1~6절) |
| `poe2-data/pob_json/` | 36MB | PoB2 원본 데이터 JSON (Gems, Skills, Bases, Uniques, Mod*, ModCache, SkillStatMap, StatDescriptions, TreeData 0.1~0.5 등) |
| `poe2-data/pob_calc/` | 6.6MB | PoB 헤드리스 계산기·상주 서버·편집기 웹 화면 원본 (README.md, setup.sh, pob_calc.py, driver.lua, serve.lua, optimizer.lua, mechdetail.lua, catalog.lua, web/, bin/luajit, gem_catalog/gem_mods/gem_text.json, loop_dps_report.md) |
| `poe2-data/poe2db/merged/` | 7MB | 한영 통합: mod_pools_kr_en.json(모드 12,778), uniques_kr_en.json(468), names_kr_en.json(17,785) |
| `poe2-data/poe2db/passive_tree/` | 6.7MB | 패시브·아틀라스 트리 원본(kr/us), 노드 한영표 |
| `poe2-data/poe2db/kr_extract/`, `us_extract/` | 62MB/11MB | 언어별 추출(pages.jsonl 등) |
| `poe2-data/poe2db/gem_cards.json`, `gem_html/` | 1.8MB/467MB | 젬 822개 한영 카드(설명·레벨·퀄리티·버프 구간·키워드 링크)와 원본 HTML |
| `poe2-data/poe2db/raw_html_full.tar` | 194MB | 전체 재수집 원본 HTML 백업(진행분) |
| `poe2-data/tags/` | 92MB | 태그·연관성·순환 고리 1차 결과 (README 6절) |
| `poe2-data/semantics/` | 15MB | 공식 문장 해석: PRINCIPLES.md(원칙), SCHEMA.md, gems_semantics(.jsonl/overrides), lines_semantics.jsonl, POB_BUGS.md, RULE_BUGS.md, build/(말뭉치·검증 리포트) |
| `poe2-data/synergy_graph/` | 4MB | 편집기 연결 그래프(nodes, ports, port_index) + 상위 빌드 8개 연결 검증 |
| `poe2-data/node_editor/` | 16MB | PoB-NodeEditor.zip(새 설치용), RELEASE.md(릴리스 절차), connection_rules_v2.md, example_check.md, verify_v2.md, 스크린샷 |
| `poe2-data/ninja_builds/` | 64MB | build_rules.md, rare_mod_power.md, tiers.json + tiers_page/(구간표 페이지), pob_codes/ + pob_codes.zip(직업 23·스킬 18별 최상위 1~10 / 상위 46~55 / 중위 91~100위 PoB 코드 1,081명), forbiddenrites/(541명 원본 chars/, builds_summary, patterns, ablation, rare_mods) |
| `poe2-data/build_search/` | 7.7MB | 3단계 자동 빌드 탐색 결과 stage1~3(.jsonl + _rank.json) |
| `poe2-data/conditions/` | 4.2MB | conditions.json(조건 지도 원본), explorer/(조건 지도 페이지 index.html + data.json) |
| `poe2-data/hidden_links/` | 5.6MB | hidden_links.json(문구 관계 분해·후보), open_view.txt(해석이 갈리는 문장/게임 규칙 문장 모음) |
| `poe2-data/tools/` | | 모든 수집·분석 스크립트 (아래 9장) |

---

## 9. 재현 방법

### 환경 준비 (새 클라우드 세션)
```bash
# 1) 데이터 복원
cd /mnt/project-files && unzip -q uploads/<업로드된 zip> -d /mnt/project-files/   # 경로 구조 그대로
# 2) PoB 계산기
bash /mnt/project-files/poe2-data/pob_calc/setup.sh
export POB_DIR=~/pob2
python3 /mnt/project-files/poe2-data/pob_calc/pob_calc.py calc --code-file code.txt
# 3) 파이썬 의존성
pip install requests beautifulsoup4 lightgbm numpy pandas
```

### 스크립트별 용도 (`poe2-data/tools/`, 각 파일 맨 위에 사용법 주석)
| 단계 | 스크립트 |
|---|---|
| PoB 데이터 → JSON | `lua_data.py`, `pob_export.py <PoB경로> <출력>`, `dump_statdesc.lua`, `parse_lines.lua` |
| poe2db 수집 | `poe2db_fetch.py --lang kr --out kr` (이어받기, 1.5초 간격) → `poe2db_extract.py`; 전체 추출 `poe2db_full_extract.py`; 젬 카드 `gem_cards.py`; 구버전 `poe2db_crawl.py`(사용 안 함), `myplay_mirror.py` |
| 태그·고리 | `build_entities.py` → `tag_entities.py` → `synergy.py` → `similar.py`; `feasibility.py`, `loop_semantics.py` |
| 문장 해석·검증 | `gem_corpus.py`, `line_corpus.py`, `sem_batch.py`, `sem_add.py`, `line_sem.py`, `sem_verify.py`, `line_verify.py`, `sem_graph.py`, `graph_rules.py` |
| 편집기 연결 그래프 | `synergy_graph.py`, `synergy_verify.py`, `make_ko.py`(한국어 용어) |
| poe.ninja | `ninja_collect.py`(공개 API, 1초 1회), `ninja_analyze.py`, `ninja_ablate.py`, `rare_mod_power.py`, `ninja_tiers.py`, `ninja_tier_codes.py` |
| 빌드 탐색 | `build_search.py` (결과를 한 줄씩 jsonl로 즉시 저장, 재시작 시 이어감) |
| 조건 지도 | `build_conditions.py` |
| 숨은 연결 | `hidden_links.py`, `value_pipes.py`, `backchain.py`(역방향) |
| 후보 검증 | `verify_candidate.py` (ninja 기준 빌드에 후보를 넣어 PoB로 DPS·EHP 차이) |
| 작업 재시작 | `restart_jobs.sh` (환경 재시작으로 끊긴 백그라운드 작업 재개) |

### 운영상 주의
- 클라우드 백그라운드 작업은 **2시간 실행 제한**이 있고 환경이 25분쯤마다 재시작될 수 있음. 긴 작업은 반드시 진행분을 파일에 즉시 저장하고 이어받기 가능하게, 시스템이 추적하는 방식(run_in_background)으로 띄울 것.
- 끝난 뒤 다음 작업이나 확인 알림을 꼭 예약할 것(밤새 멈춰 있던 사건이 두 번 있었음).
- poe2db는 1.5초 간격, poe.ninja는 1초 1회로 서버 부담 최소화. poemate.kr은 수집 금지.
- 거래소 API 우회 금지. PC에서 사용자가 직접 돌림. `POESESSID`는 비밀번호와 같으니 절대 업로드하지 않게 안내.

---

## 10. 이전 계정 링크 (참고용, 새 계정에서는 안 열릴 수 있음)
- 숨겨진 연결성 1차 탐색 (Docs): https://claude.ai/artifact/NSYiGoyjJec9ExBoU9hste → 사본 `handoff/artifacts/숨겨진_연결성_1차_탐색.md`
- 젬링 화염파 메커니즘 해석 (Docs): https://claude.ai/artifact/2Q1jRdmpcxvSroyh4Hces9 → 요약 `handoff/artifacts/젬링_화염파_메커니즘_해석_요약.md`
- PoE2 조건 지도: https://claude.ai/artifact/VbZV53oR4WjMar84kiyGqP → `poe2-data/conditions/explorer/index.html`
- poe.ninja 빌드 구간표: https://claude.ai/artifact/MKhXPk6KyDuBFtht4LCiyi → `poe2-data/ninja_builds/tiers_page/index.html`
- 저장소: https://github.com/johnyuapril/pob-nodeeditor

---

## 부록 A. 새 프로젝트에 붙여 넣을 내용

### A-1. 프로젝트 주제(Topic)
```
poe2에서 최고의 성능을 내는 빌드를 만들고 싶어. PoB를 분석해서 데미지 계산 공식을 파악하고 poe2db의 내용과 접목해서 가장 강한 성능을 내는 빌드를 만드는 게 목적이야.
```

### A-2. 프로젝트 지시문(Project instructions)
```
너는 PoE2(0.5.x, 리그 Forbidden Rites) 빌드 개발 파트너야. 목표는 고유템·혈통젬·보조젬·패시브 노드·주얼·희귀 옵션 등 가용 자원을 총동원해서, 서로 맞물려 순환하며 딜이 폭발적으로 증폭되는 "새로운" 빌드를 발견하는 거야. 상위 빌드 개선이나 단순 DPS 표기 올리기는 목표가 아니야.

작업을 시작하기 전에 공유 폴더의 handoff/HANDOFF.md 와 poe2-data/README.md, poe2-data/semantics/PRINCIPLES.md 를 읽고 이어서 작업해. 데이터·도구·결과는 모두 /mnt/project-files/poe2-data/ 아래에 있어.

원칙:
1. 속도보다 정확성. GGG 공식 문장(스킬·보조젬·아이템·노드)을 단어가 아니라 문장 단위로 정확히 이해하고, PoB 해석·PoB 수치 실험(켜고 끄기)·poe2db 원문·필요하면 웹 검색으로 교차 검증해.
2. 문구는 다각적으로 해석해서 가능성을 열어 둬. 확정 / 정황 있음 / 미확인으로 구분하고, 한 가지 뜻으로 읽고 "안 된다"고 닫지 마.
3. 빌드를 볼 때는 먼저 "어떤 메커니즘으로 딜이 나오는지"를 파악해. 조건부 효과는 조건이 충족되면 무슨 효과가 나는지, 그 조건을 어떻게 충족시키는지를 찾아.
4. 숨겨진 연결은 네가 찾아야 해. 자산(강한 효과)에서 출발하는 문제 해결형 탐색, 역방향 조건 추론, 약점 역이용, 순환 탐색, 진화형 다양성 탐색을 써. 새로움은 poe.ninja 상위 빌드가 실제로 쓰는지로 판정해.
5. 후보는 반드시 PoB 계산기(poe2-data/pob_calc, tools/verify_candidate.py)로 숫자를 뽑은 다음 보고해. PoB가 계산하지 못하는 메커니즘은 따로 표시해.
6. 한 방형 빌드는 "한 방 총량 + 재준비 시간", 지속형은 "초당 피해 + 유지 조건"으로 평가해.
7. 현실 제약(정신력, 보조 칸 5개, 능력치 요구, 무기 세트 패시브 24포인트 공유 규칙, 같은 유형 보조젬 중복 금지, 현재 획득 가능 여부)을 지켜.
8. 데이터는 빠짐없이 전부 수집·분석해. 필요한 것만 받지 마. 수집은 poe2db 1.5초 간격, poe.ninja 1초 1회. poemate.kr은 robots.txt가 AI 수집을 막으니 수집하지 마. 거래소 API 차단은 우회하지 마.
9. 모든 용어는 한국어 클라이언트 공식 표기(poe2db 한글판)로 써. 답은 한국어로.
10. 따로 지시가 없어도 다음 작업을 이어서 해. 긴 작업은 진행분을 즉시 파일에 저장하고 이어받기 가능하게 돌리고, 끝나면 다음 작업이나 확인을 예약해. 멈춘 게 있으면 먼저 솔직하게 말해.
11. 노드 편집기 수정은 poe2-data/node_editor/RELEASE.md 절차대로 version.json을 올리고 johnyuapril/pob-nodeeditor 의 main에 올려서 사용자가 업데이트 버튼으로 받게 해.
12. 내가 다른 AI의 피드백을 붙여 넣으면 그대로 따르지 말고 먼저 네 의견(동의/반대와 이유)을 말해.
```

### A-3. 첫 메시지(시작 프롬프트)
```
다른 계정에서 하던 PoE2 빌드 개발 프로젝트를 이어서 할 거야. 공유 폴더에 올린 poe2-data-core.zip 을 /mnt/project-files/ 에 그대로 풀고, handoff/HANDOFF.md 를 끝까지 읽어 줘. 그다음:
1) PoB 계산기(poe2-data/pob_calc/setup.sh)를 준비해서 예시 빌드 하나로 정상 동작을 확인하고,
2) 저장소 johnyuapril/pob-nodeeditor 상태(main v24)를 확인한 뒤,
3) HANDOFF.md 7장 "미완료 작업"을 기준으로 지금 상태를 요약하고 다음에 할 일을 추천해 줘.
마지막으로 멈춘 지점은 숨겨진 연결성 탐색 17절 이후 "진화형 다양성 탐색으로 갈지, 다른 방향으로 갈지"였어.
```
