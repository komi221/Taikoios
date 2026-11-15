# TaikoMobile (taiko-web → 네이티브 iOS)

SwiftUI + SpriteKit + AVAudioEngine. 판정/게이지 규칙은 taiko-web `gamerules.js` 그대로,
터치 입력·판정·렌더링은 새로 구현했습니다.

- 곡 목록/악보/음원: `https://cjdgrevival.com` (`/api/songs`, `/songs/<id>/main.tja|ogg`)
- 설정(⚙)에서 서버를 추가·선택·삭제할 수 있고, 서버별로 곡 목록/파일을 따로 저장
- 서버가 안 되면 우측 상단 ⤓ 버튼으로 TJA + 음원 파일을 함께 선택해서 가져오기
- 곡은 한 번 받으면 기기에 저장되어 오프라인 재생 가능

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

## 현재 구현 범위 / 남은 차이
- 원본의 전체 Canvas 렌더러를 Swift로 포팅한 것은 아니며, 메뉴·결과 화면·캐릭터 애니메이션은 아직 원본과 픽셀 단위로 같지 않습니다.
- 원본 이미지/폰트/오디오 리소스는 번들에 포함했고, 현재 게임 배경·노트 일부에 적용했습니다. 나머지 애니메이션과 화면별 리소스 연결은 후속 포팅 대상입니다.
- Audio/Video 지연값은 독립적으로 저장·적용합니다. 설정의 자동 싱크 보정에서 40회 오디오 박자 측정 후 40회 화면 플래시 측정을 진행합니다. 측정 결과는 사용자가 저장을 눌렀을 때 적용됩니다. 원본과 동일한 오디오 자산·렌더러를 그대로 포팅한 것은 아니며, 네이티브 클릭/화면 플래시 방식으로 재구현했습니다.
- 분기(#BRANCH)는 보통 분기만 사용하며 고고타임·가사·멀티플레이는 아직 미구현입니다.
- 큰 음표는 한 번 타격으로 인정(동시 타격 판정 없음).
- 화면 보정값의 부호는 원본 렌더링 타이밍에 맞춰 양수일수록 노트가 더 일찍 표시되도록 적용합니다.
- 점수는 기기 로컬에 곡 ID + 난이도별 최고 기록으로 저장합니다. 원본 서버 계정 동기화는 하지 않습니다.
- 이 환경에는 iOS SDK/Xcode가 없어 실제 iOS 빌드 및 기기 테스트는 수행하지 못했습니다. Swift 구문 파싱은 통과했으며, 최종 IPA는 GitHub Actions에서 확인해야 합니다.

## 원본 리소스
`Resources/Original/`은 사용자가 제공한 `iruka0513/taiko` 저장소 ZIP의 `public/assets/`에서 복사했습니다. 제공된 저장소 스냅샷에는 별도 LICENSE 파일이 확인되지 않았으므로, 이 프로젝트를 공개 배포할 때는 원본 코드 및 Taiko no Tatsujin 관련 리소스의 권리/배포 조건을 별도로 확인해야 합니다.
