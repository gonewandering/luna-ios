# Luna cover — sage palette

Final asset: `luna-cat-moon-cover-sage.png` (1024 × 1536 PNG).

Uses the original OpenAI Image API-generated cover with a local color grade. The cat, moon, composition, fur, digital details and framing are preserved; no new image generation was needed.

Color treatment: map neutral luminance onto the existing Luna UI palette from `ios/Luna/Views/Theme.swift`: canvas `#101613`, card `#1B2520`, line `#34483B`, sage accent `#A2CEB0`, and off-white ink `#F0F3EF`. Deep shadows blend with the app canvas; moonlight and rim lighting take the sage tint.

Original generation prompt: `luna-cat-moon-cover-prompt.txt`. Original generation used the approved OpenAI Image API CLI fallback with `gpt-image-2`; this version uses deterministic palette mapping.
