# File-type icons

The logos here are from [Simple Icons](https://simpleicons.org) 15.22.0, which
publishes them under CC0 1.0 (public domain). Each file keeps only the logo's
path, filled white, so that LavaEditor can tint it at draw time: the brand
colour is in `FileIcons.swift`, lightened on a dark theme or replaced by the
text colour where the brand's is black.

The logos are trademarks of their owners. They are used here only to say what
kind of file a tab or a row is, which is the use Simple Icons is published for;
see its [legal disclaimer](https://github.com/simple-icons/simple-icons/blob/develop/DISCLAIMER.md).

To add one: take `icons/<slug>.svg` from the same release, keep the `d` of its
single path in a file like the others, and add the slug and colour to
`FileIcons.swift`.
