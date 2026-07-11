# Privacy Policy — Local MD

**Effective: July 11, 2026**

Local MD is a fully on-device app. The short version: **we collect nothing,
transmit nothing, and track nothing.** For a health app, that isn't a
policy — it's the architecture.

- **Photos** you take or pick are analyzed by a vision model running entirely
  on your iPhone. They are never uploaded anywhere. A photo taken inside the
  app is **not saved to your photo library** and is held only in memory —
  closing the app discards it.
- **Conversations** are not stored. There is no history.
- **Voice input**, if you use it, is transcribed on-device by Apple's speech
  framework. Audio never leaves your phone.
- **Location**, if you grant it, is used only on-device for regional context
  on bites and rashes. It is never transmitted.
- **No accounts, no analytics, no ads, no third-party SDKs, no tracking.**
- The only network activity in the app is the one-time download of the
  open-source model weights from Hugging Face when you add a brain. That
  request contains no personal data. After the download the app works fully
  offline — airplane mode is the intended operating condition.

The app stores your brain selection and downloaded-model list locally on your
device. Deleting the app deletes everything.

Local MD is **not a doctor** and provides no diagnosis; see the in-app
disclaimer. It is open source — you can verify all of the above in this
repository.

Questions: open an issue on this repository.
