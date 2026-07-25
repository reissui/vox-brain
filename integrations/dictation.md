# Dictation setup

The former MacParakeet/VoiceInk/OpenSuperWhisper comparison, Karabiner rule,
Brain Note.app, and direct dictation installer are no longer production setup.

Brain includes VoxType as its optional dictation engine. Speech Setup can enable
and launch the included login item in-app; macOS may still require approval in
Login Items or a system permission prompt. A compatible standalone VoxType
installation remains supported and takes precedence over Brain's included copy.
See the [Brain.app guide](../apps/brain-menu/README.md).

Speech Setup can download and activate Brain's recommended model without
leaving Brain. Additional catalog models can be managed in Speech settings.
Configure shortcuts, recording limits, language, and output in VoxType itself.
Brain's Dictation History does not register a competing dictation shortcut,
drive VoxType's recording commands, or join its output path. It only reads the
existing local VoxType log after successful delivery. If that read fails or the
log format changes, history pauses and VoxType continues unaffected. Model
choices are documented in the
[VoxType model guide](https://voxtype.io/docs/MODEL_SELECTION_GUIDE).
