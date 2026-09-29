# Changelog

## [0.2.0](https://github.com/getathina/athina/compare/v0.1.0...v0.2.0) (2026-09-29)


### ⚠ BREAKING CHANGES

* remove the one-time move of Mentor's data ([#110](https://github.com/getathina/athina/issues/110))
* macOS keys Screen Recording and Accessibility to the bundle identifier, so both must be granted again by hand for Athina in System Settings, and the app must then be quit and reopened. The first launch also shows the system's keychain prompt for the item saved under com.ahcarpenter.mentor; Always Allow copies the key across, Deny means pasting it into Settings > Models instead. See README, "Coming from Mentor".

### Features

* add Mentor foundation with sensing, journal, and debug panel ([#1](https://github.com/getathina/athina/issues/1)) ([c9d2cf5](https://github.com/getathina/athina/commit/c9d2cf5179db1eecda46b3328bde46f830ac1bbf))
* add OpenAI and OpenCode as model providers ([#117](https://github.com/getathina/athina/issues/117)) ([3ec3ed9](https://github.com/getathina/athina/commit/3ec3ed941b820bd7084c1b4a204c92b6cbe16c68))
* **callout:** mark the spot with a pointer colour and fold notes into three kinds ([#125](https://github.com/getathina/athina/issues/125)) ([a42929d](https://github.com/getathina/athina/commit/a42929d3f9f0b16c149a98a5b61229026f038b76))
* carry a standing understanding of the user's goal across mentor calls ([#8](https://github.com/getathina/athina/issues/8)) ([d841149](https://github.com/getathina/athina/commit/d84114909881cbeea28b0106f683f618abd1747c))
* conform every Mentor surface to the macOS Human Interface Guidelines ([#9](https://github.com/getathina/athina/issues/9)) ([ccf0db1](https://github.com/getathina/athina/commit/ccf0db1a6393f5e905478fb22c85e244d0c223ec))
* **consent:** ask for consent before sensing or sending anything ([#98](https://github.com/getathina/athina/issues/98)) ([e2a97ca](https://github.com/getathina/athina/commit/e2a97ca4d5912745f5f3e356249fbe5c59313273))
* **debug-panel:** open the debug panel from Settings once enabled ([#25](https://github.com/getathina/athina/issues/25)) ([a0e829b](https://github.com/getathina/athina/commit/a0e829ba2f7b5f909cd3c7dac5d01864611c73d5))
* declare mentorship contexts and hold the mentor loop inside them ([#4](https://github.com/getathina/athina/issues/4)) ([f15680b](https://github.com/getathina/athina/commit/f15680b342e58c5bc0efa86de3388c85c4bbfd40))
* **icons:** add the app icon and an owl menu bar mark built from vector masters ([#14](https://github.com/getathina/athina/issues/14)) ([4c77c7f](https://github.com/getathina/athina/commit/4c77c7fd1132cbd21fc603634d729cc5043408c0))
* **mark:** replace the owl with the Gaze and add a glaukos accent colour ([#122](https://github.com/getathina/athina/issues/122)) ([8b62793](https://github.com/getathina/athina/commit/8b62793abd0f01391e1ed898cec477c302e5eac5))
* **menu:** name the model that answered the latest call in the menu ([#97](https://github.com/getathina/athina/issues/97)) ([04aa4bf](https://github.com/getathina/athina/commit/04aa4bfdfbc44c5338f2700d665b310cb342af9e))
* **menu:** show Debug Panel in the menu while its Settings switch is on ([#31](https://github.com/getathina/athina/issues/31)) ([de1761a](https://github.com/getathina/athina/commit/de1761aa9f7da07ab760e70cab727fcb755676b5))
* overlay callouts and push-to-talk follow-ups ([#7](https://github.com/getathina/athina/issues/7)) ([3aac6a3](https://github.com/getathina/athina/commit/3aac6a3122fbe58407042cb63012bbf0740d2fc0))
* rename the app from Mentor to Athina and migrate its data ([#18](https://github.com/getathina/athina/issues/18)) ([c24c08a](https://github.com/getathina/athina/commit/c24c08ad61b6c1274ea9e601fd26e99b9bcf5f85))
* replace the Consent and Permissions windows with one Setup window ([#127](https://github.com/getathina/athina/issues/127)) ([a1a6b8f](https://github.com/getathina/athina/commit/a1a6b8f0c1ea38369a5deaf0c27cbf60e7912083))
* **sandbox:** detect the App Sandbox at runtime and keep a sandboxed run's ids and paths its own ([#27](https://github.com/getathina/athina/issues/27)) ([d2f5ebf](https://github.com/getathina/athina/commit/d2f5ebf3a8e2ec992359759dee449a3c944dfc23))
* **settings:** fold Settings into five panes and list History by day ([#132](https://github.com/getathina/athina/issues/132)) ([b5e0fcb](https://github.com/getathina/athina/commit/b5e0fcb7098b86f8381f6a5d173116a52c20e964))
* **shortcuts:** run the global keyboard shortcuts and their recorder on KeyboardShortcuts ([#85](https://github.com/getathina/athina/issues/85)) ([ee0c682](https://github.com/getathina/athina/commit/ee0c682ee7254fcf13d5a1ef0ee69a57b3ca355c))
* two-tier Claude mentor loop with suggestion toasts and hourly spend cap ([#2](https://github.com/getathina/athina/issues/2)) ([ab58e31](https://github.com/getathina/athina/commit/ab58e31045b6175c2a40bc838addb1f8204d3d48))


### Bug fixes

* address the UI/UX review's accessibility, safety and clarity findings ([#121](https://github.com/getathina/athina/issues/121)) ([fb97d89](https://github.com/getathina/athina/commit/fb97d89aeaf4b66b49285201be130b9d29a70c61))
* **capture:** keep capture triggers noted while a capture is in flight ([#11](https://github.com/getathina/athina/issues/11)) ([aef9539](https://github.com/getathina/athina/commit/aef953922b4e6de2482ab49489984b203df245da))
* **debug-panel:** say why the debug panel shows no frame after Clear Journal ([#100](https://github.com/getathina/athina/issues/100)) ([17098e4](https://github.com/getathina/athina/commit/17098e4c18470e99a89569c67f19ca1d27091d2a))
* **debug-panel:** show each Timeline row once in the debug panel ([#28](https://github.com/getathina/athina/issues/28)) ([aede746](https://github.com/getathina/athina/commit/aede746302a900c9def4b778b30e49703dcbb445))
* hold the understanding surfaces to the macOS HIG ([#15](https://github.com/getathina/athina/issues/15)) ([195a7bc](https://github.com/getathina/athina/commit/195a7bc78f4b63b82d0a6b74ecc983fb380a668e))
* **icons:** exchange the idle and paused owl marks ([#17](https://github.com/getathina/athina/issues/17)) ([64f11f1](https://github.com/getathina/athina/commit/64f11f1def98c8faf787cf14bc42b3868bffb471))
* **journal:** keep History, the call log and the debug Timeline live via GRDB ([#102](https://github.com/getathina/athina/issues/102)) ([d71840b](https://github.com/getathina/athina/commit/d71840b5b7a47d8f926f641316b7d89ddf0918c7))
* make the audit's four small fixes - Opus 5.5 prices, --open after a bare flag, no stray -wal, dollars doc ([#83](https://github.com/getathina/athina/issues/83)) ([d58616c](https://github.com/getathina/athina/commit/d58616c26e5fc567be761ff6519d812f073e7530))
* **menu-bar:** keep the menu bar item one width in every sensing mode ([#13](https://github.com/getathina/athina/issues/13)) ([2eddc63](https://github.com/getathina/athina/commit/2eddc639759632bbcc4cf9502041710fed077f68))
* pluralize counts in the debug panel and mentor settings ([#5](https://github.com/getathina/athina/issues/5)) ([39ff274](https://github.com/getathina/athina/commit/39ff274cc036a7ffa2449bdbe87134b84bb8c528))
* **settings:** describe the owl menu bar mark in the Privacy pane's pause shortcut footer ([#66](https://github.com/getathina/athina/issues/66)) ([e5fcaec](https://github.com/getathina/athina/commit/e5fcaec1a44bee17765efe60f35fa053397e7d1c))
* **toast:** dismiss the suggestion toast on a click outside it ([#3](https://github.com/getathina/athina/issues/3)) ([4107217](https://github.com/getathina/athina/commit/41072178748300482db465ff0f3e5bcd59578f9c))


### Reverts

* restore the make check line in AGENTS.md ([#88](https://github.com/getathina/athina/issues/88)) ([92cd9e9](https://github.com/getathina/athina/commit/92cd9e921d50624b1a347e9e368199013ecca822))


### Refactoring

* remove the one-time move of Mentor's data ([#110](https://github.com/getathina/athina/issues/110)) ([2ec2d3e](https://github.com/getathina/athina/commit/2ec2d3e4fe1653d6204ea1fd9d0330ed4961be8f))
