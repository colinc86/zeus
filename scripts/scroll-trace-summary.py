"""Export and summarize target-app hitches. A missing/empty target update table cannot pass."""
import argparse, json, pathlib, subprocess, xml.etree.ElementTree as E

def summarize(directory):
    directory=pathlib.Path(directory); trace=directory/'scroll.trace'
    run=json.loads((directory/'scroll-result.json').read_text())
    toc=E.parse(directory/'toc.xml').getroot()
    seconds=float(toc.find('.//info/summary/duration').text)
    pid=toc.find('.//target/process').get('pid')
    xml=directory/'hitches.xml'
    if not xml.exists() or xml.stat().st_size == 0:
        subprocess.run(['xcrun','xctrace','export','--input',str(trace),'--xpath',
                    '/trace-toc/run[@number="1"]/data/table[@schema="hitches" or @schema="hitches-updates"]','--output',str(xml)],check=True)
    root=E.parse(xml).getroot(); refs={e.get('id'):e for e in root.iter() if e.get('id')}
    def resolve(e):
        while e is not None and e.get('ref'): e=refs[e.get('ref')]
        return e
    hitches=[]; update_count=0
    tables=toc.findall('.//data/table')
    for node in root.findall('node'):
        schema=node.find('schema')
        # xctrace emits a schema only for the first node in a multi-table export.
        import re
        index=int(re.search(r"table\[(\d+)\]",node.get('xpath')).group(1))-1
        name=schema.get('name') if schema is not None else tables[index].get('schema')
        for row in node.findall('row'):
            proc=resolve(row.find('process'))
            if proc is None:continue
            p=resolve(proc.find('pid'))
            if p is None or p.text!=pid:continue
            if name=='hitches-updates': update_count+=1;continue
            if name!='hitches':continue
            description=resolve(list(row)[-1])
            hitches.append(dict(start_s=int(resolve(row.find('start-time')).text)/1e9,
                                duration_ms=int(resolve(row.find('duration')).text)/1e6,
                                issue=description.text if description.tag=='string' else None))
    surface_valid=run.get('surface_valid', True) and 'cardOrdered=true' in run['visibility']
    traversal_valid = bool(run.get("endpoints")) and max(run["endpoints"]) > 1000
    input_valid = run.get('input') != 'window-local wheel' or (run.get('wheel_events', 0) > 0 and 'interacting' in run.get('scroll_phases', []))
    ratio=sum(h['duration_ms'] for h in hitches)/seconds
    worst=max((h['duration_ms'] for h in hitches),default=0)
    categories = {}
    for key, phrase in [('app_updates', 'app update'), ('render', 'render'), ('gpu', 'GPU'), ('unclassified', None)]:
        matching = [h for h in hitches if phrase in (h['issue'] or '')] if phrase else [h for h in hitches if not h['issue']]
        categories[key] = dict(count=len(matching), total_ms=sum(h['duration_ms'] for h in matching))
    summary=dict(hitch_categories=categories, scope='entire recording: initial seek to top plus top-bottom-top round trip',
                 capture_s=seconds,scroll_s=run['duration_s'],completed=run['completed'],surface_valid=surface_valid,traversal_valid=traversal_valid,input_valid=input_valid,target_pid=int(pid),
                 target_updates=update_count,hitch_count=len(hitches),hitch_ms_per_s=ratio,worst_hitch_ms=worst,
                 frame_budget_ms=1000/120,two_frame_limit_ms=2000/120,clock_tolerance_ms=0.001,
                 gate_pass=surface_valid and traversal_valid and input_valid and run['completed'] and update_count>0 and ratio<5 and worst<=2000/120 + 0.001,
                 worst_hitches=sorted(hitches,key=lambda h:h['duration_ms'],reverse=True)[:10])
    (directory/'hitch-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2),flush=True)
    return summary

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('directory');a=p.parse_args();summarize(a.directory)
