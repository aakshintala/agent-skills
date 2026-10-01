Read-only doc preflight for issue #__ISSUE__ in __REPO__. Do not edit anything. Do not delegate further.

Read #__ISSUE__ (`gh issue view __ISSUE__ --comments`), spec #__SPEC__ (`gh issue view __SPEC__ --comments`), and the owner rulings already posted on __RULED__ (`gh issue view N --comments`). Assume those tickets land as ruled. Then read the code on origin/main that #__ISSUE__ touches: the files it names, and their tests.

List, max 250 words total, one line each:
1. Contradictions between #__ISSUE__, #__SPEC__, the rulings and the code.
2. Defaults or formats #__ISSUE__ leaves unstated that the lane must pick.
3. Failure cases with no stated behaviour.
4. Acceptance criteria that fight the spec or the code.
For each give your recommended ruling in a few words, preferring the smallest change. End with a STATUS line.
