NimLime
=======

Super Nim Plugin for Sublime Text 2/3

Features
--------

* Syntax highlighting
* Jump to definition
* Auto-Completion
* Error checking and highlighting
* Nimble package manager integration

Installation
------------

###Latest

* Summon the command palette and select `Package Control: Add repository`
* Enter the project's URL (no .git extension!)
* Install `NimLime` through Package Control

###Stable

* Install `NimLime` through Package Control (this version is usually older than the one here)


Settings
--------

See Preferences -> PackageSettings -> NimLime

Autocompletion works per default in an on-demand mode.
This means `ctrl+space` has to be pressed again to fetch Nim compiler completions.
It can also be set into an immediate mode.

If auto-completions don't work copy the `nim_update_completions` block from the NimLime
default key bindings file to the user key bindings file.

Checking the current file automatically on-save can be enabled through the setting `check_nim_on_save`.

The path to the compiler can be configured through the setting `nim_compiler_executable`.
Per default it is set to `nim`, which means that the compiler must be in your `PATH` for the plugin to work.


Contributing
------------

Pull requests are welcome! See DEVELOPMENT.md for an overview of NimLime's design.

Clone the repository in your Sublime package directory.

Install the [AAAPackageDev](https://github.com/SublimeText/AAAPackageDev).

Modify the `.YAML-tmLanguage` files and regenerate the `.tmLanguage` files
by summoning the command palette and selecting the `Convert (YAML, JSON, PLIST) to...`
command. Don't modify the `.tmLanguage` files, they will be overwritten!
