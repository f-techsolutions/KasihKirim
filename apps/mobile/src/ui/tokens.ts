/** Brand tokens from the pitch deck. Single source — nothing hardcodes a hex. */
export const color = {
  green900: '#123D28',
  green700: '#1B5E3F',
  green600: '#2D7A52',
  green100: '#E3F0E8',
  gold:     '#F5C542',
  orange:   '#E8811E',
  cream:    '#FDF7EA',
  ink:      '#12261C',
  grey:     '#6B7B72',
  line:     '#DCE6DF',
  red:      '#C2401F',
  white:    '#FFFFFF',
} as const;

export const space = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24 } as const;
export const radius = { sm: 8, md: 11, lg: 14, pill: 999 } as const;
/** Minimum 48dp touch target — older kampung users, outdoor light. */
export const TOUCH_MIN = 48;
