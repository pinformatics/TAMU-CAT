# Image Assets Directory

This directory contains all the images used in TAMU Competency Assessment Tool.

## Required Images for Student Dashboard:

### 1. Texas A&M Logo
- **File:** `tamu-logo.png`
- **Size:** 40x40px (or larger, will be scaled)
- **Format:** PNG with transparent background
- **Usage:** Header logo next to "TEXAS A&M UNIVERSITY"

### 2. Survey Icon
- **File:** `survey-icon.png` 
- **Size:** 20x20px (or larger, will be scaled)
- **Format:** PNG with transparent background
- **Usage:** Next to each survey item in the to-do list

### 3. Notification Icon
- **File:** `notification-icon.png`
- **Size:** 24x24px (or larger, will be scaled)
- **Format:** PNG with transparent background
- **Usage:** Next to each notification in the notification center

## Image Placement Instructions:

1. Download or create the required images
2. Place them in this directory: `app/assets/images/`
3. Use the exact filenames listed above
4. Restart your Rails server after adding images

## Recommended Image Sources:

- **Texas A&M Logo:** Download from official Texas A&M brand guidelines
- **Survey Icon:** Use a document/clipboard icon (Material Design, Feather Icons, etc.)
- **Notification Icon:** Use a bell icon (Material Design, Feather Icons, etc.)

## Alternative: Using Font Icons

If you prefer not to use image files, you can replace the background images with:
- Font Awesome icons
- Material Design icons
- Unicode symbols

Example: Replace `background: url('...')` with FontAwesome classes like `fa-clipboard`, `fa-bell`, etc.
