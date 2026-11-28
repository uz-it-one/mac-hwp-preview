// Opt-in host viewer tools. Quick Look never enables these listeners or overlays.
import { svgSize } from './svg.js';
let enabled = false, scale = 1, matches = [], selected = -1, query = '';
let pinchAnchor = null;
const pages = () => [...document.querySelectorAll('#pages > .page')];
const normal = value => value.normalize('NFD').toLocaleLowerCase('ko');
const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
function matchRange(match) {
    const range = document.createRange();
    range.setStart(match.start.node, match.start.offset);
    range.setEnd(match.end.node, match.end.end);
    return range;
}
function state() {
    const list = pages();
    const current = Math.max(0, list.findIndex(p => p.getBoundingClientRect().bottom > 32));
    return { page: current + 1, count: list.length, scale, matches: matches.length, selected: selected + 1,
        limited: matches.length === 10000 };
}
function report() { if (enabled) window.webkit?.messageHandlers.viewerState?.postMessage(state()); }
function refresh() { highlight(); report(); return state(); }
function highlight() {
    document.getElementById('viewer-highlight')?.remove();
    if (selected < 0 || !matches[selected]) return;
    const match = matches[selected];
    const overlay = document.createElement('div'); overlay.id = 'viewer-highlight';
    overlay.style.cssText = 'position:absolute;left:0;top:0;pointer-events:none;z-index:1';
    try {
        for (const rect of matchRange(match).getClientRects()) {
            const box = document.createElement('div');
            box.style.cssText = `position:absolute;background:rgba(255,190,0,.35);outline:1px solid #ad7300;left:${rect.left+scrollX}px;top:${rect.top+scrollY}px;width:${rect.width}px;height:${rect.height}px`;
            overlay.append(box);
        }
        document.body.append(overlay);
    } catch { /* Document replacement invalidates ranges. */ }
}
export function enable() {
    if (enabled) return state();
    enabled = true;
    let scheduled = false;
    const changed = () => { if (!scheduled) { scheduled=true; requestAnimationFrame(() => {scheduled=false;highlight();report();}); } };
    addEventListener('scroll', changed); addEventListener('resize', changed);
    report();return state();
}
export function zoom(value) {
    if (!Number.isFinite(value)) throw new Error('invalidZoom');
    pinchAnchor = null;
    scale = clamp(value, .5, 3);
    document.getElementById('pages').style.width = `${scale*100}%`;
    return refresh();
}
export function go(page) {
    const list=pages(); if (!Number.isInteger(page) || page<1 || page>list.length) throw new Error('invalidPage');
    list[page-1].scrollIntoView({block:'start'});report();return state();
}
export function step(direction) {
    const count=pages().length;
    if(!count)return state();
    return go(clamp(state().page+(direction<0?-1:1), 1, count));
}
export function zoomBy(delta, anchorX=.5, anchorY=.5) {
    if(![delta,anchorX,anchorY].every(Number.isFinite))throw new Error('invalidZoom');
    const x=clamp(anchorX,0,1)*innerWidth;
    const y=clamp(anchorY,0,1)*innerHeight;
    const list=pages();
    // Anchor to an individual page: inter-page gaps and outer padding do not scale.
    const page=list.find(p=>p.getBoundingClientRect().bottom>=y) || list.at(-1);
    const svg=page?.querySelector('svg');
    const before=svg?.getBoundingClientRect();
    if(!before?.width || !before.height)return zoom(scale*Math.max(.01,1+delta));
    const cached=pinchAnchor;
    const unchanged=cached && cached.svg===svg && cached.x===x && cached.y===y &&
        ['left','top','width','height'].every(key=>Math.abs(cached.rect[key]-before[key])<.01);
    // Keep the original point across successive deltas instead of accumulating scroll rounding.
    const u=unchanged ? cached.u : (x-before.left)/before.width;
    const v=unchanged ? cached.v : (y-before.top)/before.height;
    zoom(scale*Math.max(.01,1+delta));
    const after=svg.getBoundingClientRect();
    scrollTo({left:scrollX+after.left+u*after.width-x,
        top:scrollY+after.top+v*after.height-y,behavior:'instant'});
    pinchAnchor={svg,u,v,x,y,rect:svg.getBoundingClientRect()};
    return refresh();
}
export function search(value, direction=1) {
    const needle=normal(String(value));
    if (query !== needle) {
        query=needle;matches=[];selected=-1;
        if (needle) for (const page of pages()) {
            let text='', map=[], previous=null;
            for (const element of page.querySelectorAll('svg text')) {
                const rect=element.getBoundingClientRect();
                if (previous && Math.abs(rect.top-previous.top)>Math.max(2,rect.height/2)) {text+='\n';map.push(null);}
                previous=rect;
                const walker=document.createTreeWalker(element,NodeFilter.SHOW_TEXT);
                while (walker.nextNode()) {
                    const node=walker.currentNode; let offset=0;
                    for (const char of node.data) {
                        const normalized=normal(char);
                        for (let i=0;i<normalized.length;i++) map.push({node,offset,end:offset+char.length});
                        text+=normalized;offset+=char.length;
                    }
                }
            }
            let from=0, at;
            while ((at=text.indexOf(needle,from))>=0 && matches.length<10000) {
                if (map[at] && map[at+needle.length-1]) matches.push({start:map[at],end:map[at+needle.length-1],page});
                from=at+Math.max(1,needle.length);
            }
            if(matches.length===10000)break;
        }
    }
    if(matches.length) {
        selected=selected<0 ? (direction<0 ? matches.length-1 : 0) : (selected+(direction<0?-1:1)+matches.length)%matches.length;
        const rect=matchRange(matches[selected]).getBoundingClientRect();scrollTo({top:Math.max(0,scrollY+rect.top-innerHeight/3),left:scrollX});
    }
    return refresh();
}
export function clearSearch() {query='';matches=[];selected=-1;refresh();}
export function pageData(index) {
    const svg=pages()[index]?.querySelector('svg');if(!svg)throw new Error('invalidPage');
    const {width,height}=svgSize(svg);
    if(!Number.isFinite(width)||!Number.isFinite(height)||width<=0||height<=0||width>20000||height>20000)throw new Error('invalidDimensions');
    return {source:new XMLSerializer().serializeToString(svg),width,height};
}
window.documentTools={enable,zoom,zoomBy,go,step,search,clearSearch,pageData,state};
