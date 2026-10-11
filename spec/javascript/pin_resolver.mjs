import { existsSync } from "node:fs"
import { pathToFileURL } from "node:url"
import { resolve as resolvePath } from "node:path"

const LIB = resolvePath("app/javascript/lib")

export async function resolve(specifier, context, nextResolve) {
  if (!specifier.startsWith(".") && !specifier.startsWith("/") && !specifier.includes(":")) {
    const candidate = resolvePath(LIB, `${specifier}.js`)
    if (candidate.startsWith(LIB) && existsSync(candidate)) {
      return { url: pathToFileURL(candidate).href, shortCircuit: true }
    }
  }
  return nextResolve(specifier, context)
}
