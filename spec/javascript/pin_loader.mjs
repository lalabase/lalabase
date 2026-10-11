// Resolves the importmap's bare names for node:test (`pin 'lane/params', to:
// 'lib/lane/params.js'`): a module under app/javascript/lib may import a sibling
// by its PIN NAME, the way the browser does, and node finds the file here. A
// relative import would be wrong in the browser (the asset pipeline digests
// file names, a relative specifier bypasses the importmap and 404s in
// production, see docs/STIMULUS_CONTROLLER_MANAGEMENT.md), so this is the one
// place the two roads meet. Only names with a file under lib/ resolve; every
// other specifier goes to node as before.
import { register } from "node:module"
import { pathToFileURL } from "node:url"

register(new URL("./pin_resolver.mjs", import.meta.url), pathToFileURL("./"))
