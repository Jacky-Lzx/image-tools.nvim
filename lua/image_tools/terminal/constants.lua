-- Module: image_tools.terminal.constants
--
-- Purpose:
--   Name fixed Kitty graphics protocol values shared by terminal services.
--
-- Architecture:
--   Provide data only to command encoding, image upload and placement owners.
--   These wire-format values are independent of user configuration.
--
-- Ownership:
--   Treat the returned table as read-only; it owns no terminal resources.

return {
  ESC = "\27",
  MAX_ID = 0xFFFFFF, -- IDs are encoded as 24-bit RGB colors.
  PNG_FORMAT = 100,
  UPLOAD_CHUNK_BYTES = 4096, -- Maximum Base64 payload per direct-upload command.
  PLACEHOLDER_CODEPOINT = 0x10EEEE,
  REPLY_ALL = 0,
  REPLY_NONE = 2,
}
