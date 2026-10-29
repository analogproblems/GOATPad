import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notes/html_markdown.dart';

void main() {
  group('formatted HTML becomes Markdown', () {
    test('a web page copied from Chrome', () {
      const html =
          "<meta charset='utf-8'><h2 style=\"color: rgb(0, 0, 0);\">"
          '<span class="mw-headline" id="History">History</span></h2>'
          '<p style="color: rgb(32, 33, 34);">The <b>quick</b> brown '
          '<a href="https://en.wikipedia.org/wiki/Fox" title="Fox">fox</a> '
          'jumps over the <i>lazy</i> dog.<sup id="cite_ref-1" '
          'class="reference"><a href="#cite_note-1">[1]</a></sup></p>\n'
          '<ul>\n  <li>One item</li>\n  <li>Second <code>item</code></li>\n'
          '</ul>';
      expect(markdownFromHtml(html), '''
## History

The **quick** brown [fox](https://en.wikipedia.org/wiki/Fox) jumps over the *lazy* dog.\\[1]

- One item
- Second `item`
''');
    });

    test('Google Docs, which wraps everything in a bold tag that is not bold', () {
      const html =
          '<meta charset="utf-8"><b style="font-weight:normal;" '
          'id="docs-internal-guid-1f2e3d4c-7fff-a1b2-c3d4">'
          '<h1 dir="ltr" style="line-height:1.38;margin-top:20pt;">'
          '<span style="font-size:20pt;font-family:Arial,sans-serif;'
          'font-weight:400;font-style:normal;">Meeting notes</span></h1>'
          '<p dir="ltr" style="line-height:1.38;"><span style="font-size:11pt;'
          'font-weight:700;font-style:normal;">Decided:</span><span '
          'style="font-size:11pt;font-weight:400;font-style:normal;"> ship '
          'on </span><span style="font-size:11pt;font-weight:400;'
          'font-style:italic;">Friday</span></p>'
          '<ul style="margin-top:0;margin-bottom:0;">'
          '<li dir="ltr" style="list-style-type:disc;" aria-level="1">'
          '<p dir="ltr" role="presentation"><span style="font-weight:400;">'
          'Write the release notes</span></p></li>'
          '<ul><li dir="ltr" aria-level="2"><p dir="ltr" role="presentation">'
          '<span style="font-weight:400;">Ask Milo</span></p></li></ul>'
          '<li dir="ltr" aria-level="1"><p dir="ltr" role="presentation">'
          '<span style="text-decoration:line-through;font-weight:400;">'
          'Old idea</span></p></li></ul><br></b>';
      expect(markdownFromHtml(html), '''
# Meeting notes

**Decided:** ship on *Friday*

- Write the release notes
    - Ask Milo
- ~~Old idea~~
''');
    });

    test('Word, which writes lists as paragraphs', () {
      const html = '''
<html xmlns:o="urn:schemas-microsoft-com:office:office">
<head><meta charset="utf-8"><style><!--
p.MsoNormal {margin:0in; font-size:11.0pt;}
--></style></head>
<body lang=EN-US style='tab-interval:.5in'>
<!--StartFragment-->
<p class=MsoNormal><b><span style='font-size:14.0pt'>Quarterly plan<o:p></o:p></span></b></p>
<p class=MsoListParagraphCxSpFirst style='text-indent:-.25in;mso-list:l0 level1 lfo1'><![if !supportLists]><span style='font-family:Symbol'><span style='mso-list:Ignore'>·<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
</span></span></span><![endif]>Ship part four<o:p></o:p></p>
<p class=MsoListParagraphCxSpLast style='margin-left:1.0in;text-indent:-.25in;mso-list:l0 level2 lfo1'><![if !supportLists]><span style='font-family:"Courier New"'><span style='mso-list:Ignore'>o<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp;
</span></span></span><![endif]>Write <i>tests</i><o:p></o:p></p>
<p class=MsoListParagraph style='text-indent:-.25in;mso-list:l1 level1 lfo2'><![if !supportLists]><span><span style='mso-list:Ignore'>1.<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp;&nbsp;&nbsp;
</span></span></span><![endif]>First step<o:p></o:p></p>
<p class=MsoNormal>Run <span style='font-family:"Courier New"'>make</span> after.<o:p>&nbsp;</o:p></p>
<!--EndFragment-->
</body></html>''';
      expect(markdownFromHtml(html), '''
**Quarterly plan**

- Ship part four
    - Write *tests*
1. First step

Run `make` after.
''');
    });

    test('a GitHub README with code, a table and a task list', () {
      const html = '''
<h2 dir="auto">Install</h2>
<div class="highlight highlight-source-shell notranslate position-relative overflow-auto" dir="auto"><pre>npm install gpad
  <span class="pl-c"><span class="pl-c">#</span> then</span>
gpad --help</pre></div>
<markdown-accessiblity-table><table>
<thead><tr><th>Key</th><th>What it does</th></tr></thead>
<tbody><tr><td><kbd>Ctrl+N</kbd></td><td>New note | tab</td></tr>
<tr><td><kbd>Ctrl+P</kbd></td><td colspan="2">Search</td></tr></tbody>
</table></markdown-accessiblity-table>
<ul class="contains-task-list">
<li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled="" checked=""> Folders</li>
<li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled=""> Sync</li>
</ul>''';
      expect(markdownFromHtml(html), '''
## Install

```shell
npm install gpad
  # then
gpad --help
```

| Key | What it does |  |
| --- | --- | --- |
| `Ctrl+N` | New note \\| tab |  |
| `Ctrl+P` | Search |  |

- [x] Folders
- [ ] Sync
''');
    });

    test('a spreadsheet range becomes a table', () {
      const html =
          '<google-sheets-html-origin><style type="text/css">td {border: 1px solid #cccccc;}</style>'
          '<table cellspacing="0" cellpadding="0" dir="ltr" border="1">'
          '<colgroup><col width="100"><col width="100"></colgroup><tbody>'
          '<tr style="height:21px;"><td>Name</td><td>Notes</td></tr>'
          '<tr style="height:21px;"><td>Jason</td><td>12</td></tr>'
          '</tbody></table>';
      expect(
        markdownFromHtml(html),
        '| Name | Notes |\n| --- | --- |\n| Jason | 12 |\n',
      );
    });

    test('an email laid out with tables reads as its paragraphs', () {
      const html = '''
<table width="100%"><tr><td>
  <table><tr>
    <td><p><b>Hello Jason,</b></p><p>Your order has shipped.</p></td>
    <td><img src="https://mail.example.com/open.gif" width="1" height="1"></td>
  </tr></table>
  <p><a href="javascript:alert(1)">Click me</a> or <a href="https://example.com/track">track it</a>.</p>
  <div style="display:none">Hidden preview text</div>
</td></tr></table>''';
      expect(markdownFromHtml(html), '''
**Hello Jason,**

Your order has shipped.

Click me or [track it](https://example.com/track).
''');
    });

    test('images keep their alt text, and only web images are kept', () {
      const html =
          '<p>Logo: <img src="https://example.com/logo.png" alt="GPad logo" '
          'title="Our logo"> and <img src="data:image/png;base64,AAAA" '
          'alt="pasted"> and <img src="file:///C:/Users/me/x.png"></p>'
          '<p><a href="/relative/page">Relative</a> <a href="https://example.com">'
          '<img src="https://example.com/badge.svg" alt="badge"></a></p>';
      expect(markdownFromHtml(html), '''
Logo: ![GPad logo](https://example.com/logo.png "Our logo") and and

Relative [![badge](https://example.com/badge.svg)](https://example.com)
''');
    });

    test('quotes, rules and line breaks', () {
      const html =
          '<blockquote><p>First line<br>second line</p></blockquote>'
          '<hr><p>After&nbsp;&nbsp;the   rule</p>';
      expect(markdownFromHtml(html), '''
> First line
> second line

---

After the rule
''');
    });

    test('a code block keeps its spacing and language', () {
      const html =
          '<h3>Example</h3><pre class="language-dart"><code>void main() {\n'
          '  print(1);\n\n}\n</code></pre>';
      expect(markdownFromHtml(html), '''
### Example

```dart
void main() {
  print(1);

}
```
''');
    });
  });

  group('HTML with no formatting is left to the plain text', () {
    test('code copied from VS Code', () {
      const html =
          "<meta charset='utf-8'><div style=\"color: #cccccc;background-color: "
          "#1f1f1f;font-family: 'Droid Sans Mono', 'monospace', monospace;"
          'font-weight: normal;font-size: 14px;line-height: 19px;white-space: '
          'pre;"><div><span style="color: #569cd6;">const</span><span '
          'style="color: #cccccc;"> x </span><span style="color: #d4d4d4;'
          'font-weight: bold;">=</span><span style="color: #b5cea8;"> 1;'
          '</span></div><br><div><span style="color: #cccccc;">x++;</span>'
          '</div></div>';
      expect(markdownFromHtml(html), isNull);
    });

    test('a code block alone', () {
      expect(markdownFromHtml('<pre><code>SELECT 1;</code></pre>'), isNull);
    });

    test('styled but unformatted text', () {
      expect(
        markdownFromHtml(
          '<div dir="ltr"><span style="color:#222">Hi Jason,</span><br>'
          'See you at <span style="font-size:13px">3pm</span>.</div>',
        ),
        isNull,
      );
    });

    test('a single spreadsheet cell', () {
      expect(markdownFromHtml('<table><tr><td>42</td></tr></table>'), isNull);
    });

    test('a huge copy', () {
      final html = '<b>bold</b>${' ' * maxClipboardHtmlLength}';
      expect(markdownFromHtml(html), isNull);
    });

    test('nothing at all', () {
      expect(markdownFromHtml(''), isNull);
      expect(markdownFromHtml('<b> </b>'), isNull);
    });
  });
}
