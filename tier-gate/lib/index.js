/**
 * phone-armor-tier-gate — 服务端半边。
 *
 * 纯 UI 插件：host 侧不需要任何行为。空 apply 的存在只是为了让插件出现在
 * cordis.yml / Loader 里；浏览器半边通过 package.json 的 dsh.client 声明发现，
 * 走 exports["./client"]。
 */

/** Host plugin body — 这个闸门不需要服务端逻辑。 */
function apply() {}

export { apply };
