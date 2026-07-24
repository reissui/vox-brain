# Retired: standalone dictation setup

The former MacParakeet/VoiceInk/OpenSuperWhisper comparison, Karabiner rule,
Brain Note.app, and direct dictation installer are no longer production setup.

Use VoxType as the standalone dictation application. [Brain.app](../apps/brain-menu/README.md) only verifies
that the separately installed service is available for meeting transcription
and displays its status and configured shortcut read-only. See the
[Brain.app guide](../apps/brain-menu/README.md).

Configure shortcuts, models, recording limits, language, transcription, and
output in VoxType itself. Brain's Dictation History does not edit VoxType
configuration, restart VoxType, register a competing dictation shortcut, drive
its recording commands, or join its output path. It only reads the existing
local VoxType log after successful delivery. If that read fails or the log
format changes, history pauses and VoxType continues unaffected. Model choices are documented in the
[VoxType model guide](https://voxtype.io/docs/MODEL_SELECTION_GUIDE).
