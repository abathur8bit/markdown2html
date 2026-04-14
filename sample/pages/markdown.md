# Markdown
Using [markdown](https://pub.dev/packages/markdown) dart package, so you have pretty good markdown support.

## Basic Formatting

- **Bold**: `**Bold**`
- _Emphasized_: `*Emphasized*`
- Strikethrough : `~~Strikethrough~~`
- Horizontal rules: `---` (three hyphens), `***` (three asterisks), or `___` (three underscores).

## Headings

All heading levels (e.g. H1, H2, etc), are marked by `#` at the beginning of a line. For example, an H1 is `# Heading 1` and an H2 is `## Heading 2`. This continues to `###### Heading 6`.

## Links

Links can be created using several methods:

- Links can be `[inline](https://markdowntohtml.com)`
- Inline links can `[have a title](https://markdowntohtml.com "Awesome Markdown Converter")`

## Lists (Ordered Lists and Unordered Lists)

Lists are made by using indentation and a beginning-of-line marker to indicate a list item. For example, unordered lists are made like this:

* One item
* Another item
  * A sub-item
    * A deeper item
  * Back in sub-item land
* And back at the main level

Unordered lists can use an asterisk (`*`), plus (`+`), or minus (`-`) to indicate each list item.

Ordered lists use a number at the beginning of the line. The numbers do not need to be incremented - this will happen for you automatically by the HTML. That makes it easier to re-order your ordered lists (in markdown) as needed.

Also, ordered and unordered lists can be nested within each other. For example:

* One item
* Another item
  1. A nested ordered list
  1. This is the second item
    * And now an unordered list as its child
    * Another item in this list
  1. One more in the ordered list
* And back at the main level

### Code and Syntax Highlighting

Inline code uses `` `backticks` `` around it. Code blocks are either fenced by three backticks (` ``` `) or indented four spaces. For example:

````
```
var foo = 'bar';

function baz(s) {
   return foo + ':' + s;
}
```
````

### Blockquotes

Use `>` to offset text as a blockquote. For example:

```
> This is some part of a blockquote.
> Some more stuff.
```

Will produce:  
  