# pencil.koplugin

## Information

This has been tested on:

- Kobo Libra Color/Kobo Pencil 2/Epub format

Due to Kobo's pencil tools not being bluetooth devices, there is no way to intercept the side button click, or to differentiate between the eraser side and stylus side.

If you resize your book while reading it, your annotations will be WONKY. This is something I will eventually address but for now, get your book set before you start writing.

## Instructions for Installation

1. Download both the `pencil.koplugin` directory and the `input.lua` file from this repository.
2. Replace the `/frontend/device/input.lua` with the downloaded file. This enables the plugin to intercept the stylus input and separate it from touch inputs.
3. Copy the `pencil.koplugin` directory into the `/plugins` directory of koreader.

## Configuring the Pencil Plugin

1. Enable the plugin within koreader
2. Set the tool toggle to a gesture within Gesture Manager

## Questions or Issues with the Plugin

If you have any questions or a feature request, please submit an issue in this repo.
If you're experiencing issues with the plugin, please provide your `.adds/koreader/pencil_input_debug.log` (you may need to enable debugging in the plugin settings) and describe the problem in an issue in this repo.

## Feautres In the Pipeline

1. Annotation color selection
2. Export of annotions of some kind
3. Handling changing canvas size.

xoxo
