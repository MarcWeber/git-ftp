README of git-ftp-minimal
==========================

# KISS version of git-ftp (original code: https://github.com/resmo/git-ftp)

* This application is licenced under [GNU General Public License, Version 3.0]

Summary
-------

differential update via FTP based on git checking only if files are not
modified on the server (preserving others work).


Usage
-----
1) Create a file git-ftp-minimal.config:


    REMOTE_USER="USER"
    REMOTE_PASSWD="PASSWORD"

    URL="ftp://FTP_SERVER.XY"

    # ignore these files:
    filter(){ grep -v "gitignore"; }


2) cp git-ftp-minimal.sh into your project directory

sync up:

    git-ftp-minimal.sh --sync


[GNU General Public License, Version 3.0]: http://www.gnu.org/licenses/gpl-3.0-standalone.html
