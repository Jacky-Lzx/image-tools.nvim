-- Module: image_tools.media.conversion_limits
--
-- Purpose:
--   Name fixed output and subprocess resource limits for image conversion.
--
-- Architecture:
--   Preview and clipboard command builders share ImageMagick limits. Preview
--   renderers share a default output box, scaled for viewer detail independently
--   of terminal cells and constrained by configured validation limits.
--
-- Ownership:
--   Treat the returned table as read-only; command builders own their arrays.

return {
  MAX_WIDTH = 1920,
  MAX_HEIGHT = 1080,
  MAGICK_MEMORY = "128MiB",
  MAGICK_MAP = "256MiB",
  MAGICK_DISK = "256MiB",
}
