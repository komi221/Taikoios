# TaikoMobile (taiko-web → 네이티브 iOS)

SwiftUI + SpriteKit + AVAudioEngine. 판정/게이지 규칙은 taiko-web `gamerules.js` 그대로,
터치 입력·판정·렌더링은 새로 구현했습니다.

- 곡 목록/악보/음원: `https://cjdgrevival.com` (`/api/songs`, `/songs/<id>/main.tja|ogg`)
- 설정(⚙)에서 서버를 추가·선택·삭제할 수 있고, 서버별로 곡 목록/파일을 따로 저장
- 서버가 안 되면 우측 상단 ⤓ 버튼으로 TJA + 음원 파일을 함께 선택해서 가져오기
- 곡은 한 번 받으면 기기에 저장되어 오프라인 재생 가능

## 원본 리소스 사용
taiko-web의 이미지(음표·북·돈쨩 애니메이션·배경·터치 드럼 등), 효과음, 폰트(TnT, Kozuka)를
`Resources/`에 그대로 넣어 사용합니다. 게임 화면은 원본 view.js와 같은 1280x720 좌표/크기로 배치했고,
판정 입력은 원본 터치 드럼(타원 안=돈, 밖=카)과 같은 방식입니다.

## IPA 만들기

### A. Mac 없이 (GitHub Actions)
1. 이 폴더를 GitHub 저장소(main 브랜치)에 올립니다.
2. Actions 탭 → "Build IPA" 실행 → 끝나면 Artifacts의 `TaikoMobile-ipa` 다운로드
3. 서명 없는 IPA라서 LiveContainer / AltStore / Sideloadly 등으로 설치 시 서명됩니다.

### B. Mac + Xcode
```bash
bash scripts/fetch_deps.sh      # stb_vorbis.c 다운로드 (ogg 디코더)
brew install xcodegen
xcodegen generate
open TaikoMobile.xcodeproj      # Signing 팀 지정 후 실행
```

## 조작
화면 아래 4칸: 왼쪽 바깥=카, 안쪽 두 칸=돈, 오른쪽 바깥=카. 멀티터치 지원.
설정(⚙)에서 판정 보정(ms)과 노트 속도 조절.

## 화면 구성 (원본 재현)
- 타이틀: title-screen.png + vectors.json 으로 그린 원본 로고 (logo.js 포팅)
- 게임: 돈 배경(스크롤)·곡 배경·무대·돈쨩·북·고고 불꽃·노트 폭발·터치 드럼
- 결과: scoresheet.js 의 레이아웃/색 (1280x720 기준)

## 점수 저장 / 최근 플레이
- 곡·난이도별 최고점, 최대 콤보, 왕관(클리어=은, 풀콤보=금)을 기기에 저장 (`scores.json`)
- 곡 목록 맨 위에 "최근 플레이"(최대 5곡), 각 곡 아래에 난이도별 최고 기록 표시
- 저장 규칙은 원본 scoresheet.saveScore 와 같음 (기존 점수 이하일 때만 기록 갱신, 더 높은 왕관은 유지)

## 지연(싱크) 설정
- 설정 ⚙ → 판정 보정 −250 ~ +500 ms
- "기기 출력 지연 자동 반영": iOS 가 알려주는 출력 지연(블루투스 이어폰 등)을 자동 보정. 직접 맞춘 값이 있으면 끄고 사용

## 성능 (프레임 드랍 수정)
- 터치 시 SKAction/라벨 재생성 제거 → 마지막 입력 시각만 기록하고 화면 효과는 update() 가 시각으로 계산
- 점수/콤보/풍선 숫자는 미리 만든 글자 텍스처 스프라이트(텍스트 재래스터라이즈 없음)
- SKCropNode(매 프레임 오프스크린 렌더)·SKShapeNode 제거, 연타 몸통/슬롯/패널은 텍스처 한 장씩
- 노트 노드 풀링, 활성 노트만 순회, 고고 구간 포인터 방식
- 텍스처(돈쨩 시트 포함)와 콤보 음성/풍선 효과음을 곡 시작 전에 미리 GPU 업로드·디코딩
- 기본 60fps, 설정에서 120fps 선택 가능

## 알려진 한계
- 분기(#BRANCH)는 보통 분기만 사용, 가사·멀티플레이·계정 없음
- 큰 음표는 한 번 타격으로 인정(동시 타격 판정 없음)
- 노트 아래 글씨(ドン/カッ), 결과 화면의 꽃·미코시·테츠오하나 연출은 아직 없음
- 이 환경에서는 Swift 컴파일을 못 해봐서 첫 빌드에서 오타성 오류가 날 수 있음
