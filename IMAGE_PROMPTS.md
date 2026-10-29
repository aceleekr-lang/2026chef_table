# 셰프의 테이블 — ChatGPT 이미지 생성 프롬프트

앱 `img/` 폴더에 아래 파일명으로 저장하면 자동 적용됩니다 (없으면 CSS 장식으로 대체되므로 없어도 동작함).
톤앤매너: **블랙 & 골드, 파인다이닝, 미슐랭 레스토랑의 고요한 고급감.** 실제 인물(강레오 셰프 얼굴)은 생성하지 않습니다.

공통 스타일 문구(프롬프트 끝에 붙이기):
> Luxury fine-dining aesthetic, matte black background, warm champagne-gold accents, soft dramatic rim light, shallow depth of field, editorial food photography, cinematic, ultra-detailed, no text, no watermark, no people's faces.

---

## 1. `img/hero.jpg` — 메인 배경 (세로 9:16, 1080×1920)
```
A single exquisite fine-dining plate on a matte black stone table, seen from a low three-quarter angle. Glossy deep-red Korean chili oil drizzled in an elegant arc, a few perfectly placed red chili threads and micro herbs, a thin brushed-gold rim on the plate. Dark moody restaurant interior softly blurred behind, one warm candle-like highlight. Gold dust particles floating in the air. Vertical 9:16 composition with empty dark space in the lower third for text overlay.
+ (공통 스타일 문구)
```

## 2. `img/medal.png` — 룰렛 중앙 메달 (정사각 1024×1024, 투명 배경)
```
A circular embossed gold medallion seal, like a wax-seal or Michelin-style emblem, engraved with a stylized chef's hat and crossed knife & fork, laurel wreath border, brushed antique gold with fine engraved texture, subtle bevel highlights. Centered, isolated on a transparent background, PNG, no text.
```

## 3. `img/ticket-bg.jpg` — 시식권 배경 (세로 3:4, 1200×1600)
```
A luxurious dark textured paper background for a VIP tasting ticket: deep charcoal-black linen texture with faint gold foil guilloché pattern around the edges, thin double gold border frame, very subtle gold floral damask watermark in the center, soft vignette. Empty center for text. No text, no logos.
```

## 4. `img/logo.png` — 워드마크 (가로, 투명 배경, 1600×600)
```
Elegant gold wordmark logo on transparent background: the Korean text "셰프의 테이블" in a refined high-contrast serif typeface (like a luxury restaurant logo), with a thin gold ornamental line above and below and a small chef's hat icon above. Brushed gold metallic finish, PNG, transparent background.
```
> ChatGPT가 한글 글자를 틀리게 그리면 영문 "CHEF'S TABLE"로 만든 뒤 한글은 앱의 기본 서체 제목을 그대로 쓰세요(로고 없이도 자동 표시).

## 5. (선택) `img/og.jpg` — 카카오톡/문자 링크 미리보기 (가로 1200×630)
```
Wide banner: a fine-dining tasting course lined up on black slate, miniature Korean spicy dishes with glossy red glazes, gold cutlery, dramatic side lighting, generous empty dark space on the left half for a title.
+ (공통 스타일 문구)
```

## 6. (선택) 현장 QR 배너용 포스터 (세로 A1/A2, 2:3)
```
Fine-dining event poster background: black velvet backdrop, a single gold-rimmed plate spotlighted from above, rising wisps of steam catching gold light, scattered dried red chili petals, large empty area at the top and bottom for Korean title and a QR code.
+ (공통 스타일 문구)
```

---
### 팁
- 생성 후 **jpg 품질 80%, 1080px 폭**으로 줄여서 넣으면 현장 LTE에서도 빠르게 뜹니다.
- 메달·로고 PNG는 투명 배경이 중요합니다. ChatGPT 결과가 배경을 채워 오면 "transparent background PNG, isolated object"를 다시 강조하세요.
- 인물 사진은 넣지 않는 것을 권장합니다(초상권·톤 일관성).
