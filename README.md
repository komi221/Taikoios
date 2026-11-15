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

## 알려진 한계 (1차 버전)
- 분기(#BRANCH)는 보통 분기만 사용, 고고타임·가사·멀티플레이·계정/점수 저장 없음
- 큰 음표는 한 번 타격으로 인정(동시 타격 판정 없음)
- 이 환경에서는 Swift 컴파일을 못 해봐서 첫 빌드에서 오타성 오류가 날 수 있음
