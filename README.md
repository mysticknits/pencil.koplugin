# pencil.koplugin

## Information

This has been tested on:

- Kobo Libra Colour/Kobo Stylus 2/Epub format

**This will currently only work on Kobo devices! I will attempt to add other device support by request and at a later date**

If you resize your book while reading it, your annotations will be WONKY. This is something I will eventually address but for now, get your book set before you start writing.

## Features

- **Pen tip**: Draw annotations on your ebooks
- **Eraser end**: Flip your stylus over to erase strokes instantly
- **Undo**: Undo your last stroke or eraser action
- **Per-document storage**: Annotations are saved with each book

## Instructions for Installation

1. Download both the `pencil.koplugin` directory and the `input.lua` file from this repository.
2. Replace the `/frontend/device/input.lua` with the downloaded file. This enables the plugin to intercept the stylus input, separate it from touch inputs, and detect the eraser end.
3. Copy the `pencil.koplugin` directory into the `/plugins` directory of KOReader.

## Configuring the Pencil Plugin

1. Enable the plugin within KOReader's plugin management
2. Optionally set tool toggle to a gesture within Gesture Manager

## Questions or Issues with the Plugin

If you have any questions or a feature request, please submit an issue in this repo.
If you're experiencing issues with the plugin, please provide your `.adds/koreader/pencil_input_debug.log` (you may need to enable debugging in the plugin settings) and describe the problem in an issue in this repo.

## Features In the Pipeline

1. Annotation color selection
2. Export of annotations of some kind
3. Handling changing canvas size

## Acknowledgements

Eraser end detection based on techniques from [eraser.koplugin](https://github.com/SimonLiu423/eraser.koplugin) by SimonLiu.

xoxo
