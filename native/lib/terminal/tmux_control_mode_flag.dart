// Feature flag for the tmux control-mode (`tmux -CC`) integration arc (epic #906).
//
// Part A (#907) builds + validates a PURE control-mode parser only; it changes
// NOTHING in the live scrape/render/gesture path. Parts B (render via control
// mode) and C (gestures via control mode) will read this flag to switch the
// session layer onto the parser. Until then it stays OFF so the proven
// screen-scrape path remains the default.
//
// Kept as a compile-time const so a false value tree-shakes the (future) wiring
// entirely out of release builds while the spike matures.
const bool tmuxControlMode = false;
