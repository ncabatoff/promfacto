# promfacto
Factorio 0.12 mod to export [Prometheus](https://prometheus.io/) metrics.  

## Why?

In the early stages of the game factories are small and it's fairly easy to
keep taps on what's happening.  Even then, depending on what you have available
in starting resources, it may not be easy to see everything happening even at
the most zoomed-out mode.

There are some great in-game production metrics already available by hitting
'p', and power metrics can be had by clicking on power poles.  Some of us would
like more, and would like to use the power of Grafana and PromQL to visualize
metrics.

## What?

See the Metrics section below for the full list.  You'll be able to see what's being
built in your factory in terms of furnaces, assembling machines, accumulators, and
fluid levels.  You can see world metrics like pollution and deaths.

Using a modified version of [YARM](https://github.com/narc0tiq/YARM) you can
get metrics on resource consumption and remaining resources.  In other words,
the data you could see on your in-game resource monitor is also published for
Prometheus.  This requires that you complete the research to get the in-game
equivalent, aka 'resource-monitoring'.

Using a modified version of
[Advanced Logistic System](https://github.com/anoutsider/advanced-logistics-system) 
you can get metrics on container contents.  As with YARM, this merely exposes to
Prometheus what was already visible in the in-game GUI, so you have to unlock
the tech and build the controller before metrics will be written.


## How?

Prometheus periodically does an HTTP GET to all configured metrics exporters, and
stores the metrics they publish in an internal DB.  Grafana queries that DB to visualize
the data.

node-exporter is primarily a tool for collecting OS metrics, but it also has an option
to let it read metrics from files in a directory.  These factorio mods write files in
that directory.

## Requirements

Only tested on Factorio 0.12.35 single-player.  Only tested on Ubuntu 14.04 and 16.04,
should work on any Linux system but if you can't run Docker it'll be more involved
(no instructions provided in that case.)  

## Installation

If you already have the real versions of YARM or Advanced Logistic System
installed, remove them.

Download the promfacto, YARM and Advanced Logistic System zip files from 
[the release page](https://github.com/ncabatoff/promfacto/releases/tag/0.1.3)
and place them in the mods/ directory within your Factorio install.

You'll need Prometheus, node-exporter and Grafana as well to make proper use of
the metrics emitted.  You can build them from source, or use Docker.  If you're not
familiar with docker, visit [docker.com](http://www.docker.com) to install it.

    mkdir -p ~/promfacto/prometheus
    cat > ~/promfacto/prometheus/prometheus.yml << EOF
    scrape_configs:
      - job_name: 'node'
        static_configs:
             - targets: ['localhost:9100']
    EOF
    
    docker run -d --net="host" -v ~/factorio/script-output/metrics/:/textfiles prom/node-exporter  -collector.textfile.directory=/textfiles
    docker run -d --net="host" -v ~/promfacto/prometheus_data:/prometheus -v ~/promfacto/prometheus:/etc/prometheus prom/prometheus
    docker run -d -p 3000:3000 -v ~/promfacto/grafana:/var/lib/grafana grafana/grafana

You may need to use sudo for the docker commands, depending on your OS and version.
Also, these instructions assume that you installed Factorio into ~/factorio, if that's not
the case update the node-exporter command accordingly.

Test by going to [http://localhost:9090/targets](http://localhost:9090/targets).
This is the Prometheus target status page, which will hopefully show that Prometheus is
successfully scraping node-exporter, i.e. that it has status UP.

Assuming it is, you can now link Grafana to Prometheus so we'll have a way to look at the data:

    curl -X POST -H 'Content-Type: application/json;charset=UTF-8' --data-binary '{"name":"prometheus","type":"prometheus","url":"http://localhost:9090","access":"direct","isDefault":true,"user":"admin","password":"admin"}' http://admin:admin@localhost:3000/api/datasources ; echo

curl might not be installed on your system, in which case you could install it or simply define
the data source in Grafana by hand - it's not hard.

If it worked you should see something like this:

    ncc@xal:~/src/github.com/ncabatoff/promfacto$ curl -X POST -H 'Content-Type: application/json;charset=UTF-8' --data-binary '{"name":"prometheus","type":"prometheus","url":"http://localhost:9090","access":"direct","isDefault":true,"user":"admin","password":"admin"}' http://admin:admin@localhost:3000/api/datasources ; echo
    {"id":1,"message":"Datasource added"}

### Setup dashboards from grafana.net

Login to your Grafana at [http://localhost:3000](http://localhost:3000) using username admin and password admin.

Click on the pulldown menu in the upper left with the square on it, next to the
spiral menu in the upper left hand coerner.  Choose Import, and in the 'Grafana.net Dashboard' input box put
285, then click Load.  Now under Options click on 'Select a Prometheus data source' and choose the only option,
'prometheus'.  Click 'Save & Open'.

You're ready to go, start a game and give it a try.


## Tips

### Reduce Prometheus memory usage

You can make Prometheus use less memory by giving the argument -storage.local.memory-chunks=50000 (that
number is still pretty generous, you can try smaller values too):

    sudo killall prometheus
    docker run -d --net="host" -v ~/promfacto/prometheus_data:/prometheus -v ~/promfacto/prometheus:/etc/prometheus prom/prometheus -storage.local.memory-chunks=50000 -config.file=/etc/prometheus/prometheus.yml -storage.local.path=/prometheus

The extra config.file and storage.local.path arguments are needed because once we give Docker program arguments
the ones in the dockerfile get ignored.

### Adjust your retention period

How long do you want to keep your metrics for?  They don't take up very much space on disk, but if you're
concerned about performance or memory use, keeping a lower retention is one way to keep the impact on your
system modest.  Use -storage.local.retention=duration to set that duration: data older than that duration
gets deleted automatically.  For example, to keep two days worth:

    sudo killall prometheus
    docker run -d --net="host" -v ~/promfacto/prometheus_data:/prometheus -v ~/promfacto/prometheus:/etc/prometheus prom/prometheus -storage.local.retention=48h -config.file=/etc/prometheus/prometheus.yml -storage.local.path=/prometheus

### Adjust your sampling rate

The more often you collect metrics, the more detailed they are.  The flip side is that sometimes you don't
need as much granularity as you think, and the more granular your metrics the more expensive they are
in terms of memory and CPU and disk space.  The default sampling period is 15s, but you can adjust it in
the config file.  For example, to move to a 30s sampling period:

    cat > ~/promfacto/prometheus/prometheus.yml << EOF
    scrape_configs:
      - job_name: 'node'
        scrape_interval: 30s
        static_configs:
             - targets: ['localhost:9100']
    EOF
    sudo killall -HUP prometheus

The mod itself only emits metrics every 10s, you'll have to modify control.lua if you want to sample more
frequently than that.  Look for event.tick % 600 and change it to 60 times the number of seconds desired
as the new interval.

### Use another machine to reduce load on your game machine

You don't have to run anything except node-exporter on the same machine as the game is running on.
If you're having performance issues and you have a spare machine (e.g. a laptop), consider running
Prometheus, Grafana, and your browser on other hosts.  You'll have to modify the above instructions,
replacing localhost with the name of the machine on which the game is played.

### Use another machine for convenience

Even if you're not having performance issues you may still want to involve another screen somehow
so you can see the metrics and the game at the same time.  You can connect to Grafana from a laptop
(or tablet, phone, etc) by going to http://game-machine-host-name:3000.

## Metrics

### factorio_deaths

counter: how many entities have died

* entity_name

### factorio_objects

gauge: how many items owned by player

* force: 'player' in single-player games
* name
* placement: always 'inventory' for this mod

### factorio_sectors_scanned

counter: how many radar sectors have been scanned

### factorio_chunks_generated

gauge: number of active 32x32-tile chunks

### factorio_pollution_total

gauge: total pollution

### factorio_evolution_factor

gauge: evolution_factor

### factorio_fluid_stored

gauge: fluid stored

* force: 'player' in single-player games
* resource_name

### factorio_energy

gauge: total energy

* force: 'player' in single-player games
* entity_name: 'furnaces' or 'accumulators' only for now

### factorio_crafting

gauge: how many assembling machines are working

* force: 'player' in single-player games
* entity_name: thing being crafted (should probably be called recipe instead)

### factorio_hasoutput

gauge: how many assembling machines have nonempty output inventories

* force: 'player' in single-player games
* entity_name: thing being crafted (should probably be called recipe instead)

### factorio_hasinput

gauge: how many assembling machines have nonempty input inventories

* force: 'player' in single-player games
* entity_name: thing being crafted (should probably be called recipe instead)

### factorio_assemblers

gauge: how many assembling machines have recipes

* force: 'player' in single-player games
* entity_name: thing being crafted (should probably be called recipe instead)

### factorio_furnaces

gauge: how many furnaces are doing what

* force: 'player' in single-player games
* product: what the furnace is smelting (based on its output inventory, 'unknown' if none)
* status: 'idle', 'crafting no outputs', 'crafting with outputs'

### [YARM] factorio\_resource\_mined\_total

counter: how many of each resource have been mined

* force: 'player' in single-player games
* resource_name: 'coal', 'stone', etc
* site_name: "same as in the in-game resource monitor, e.g. S76"

### [YARM] factorio\_resource\_remaining

gauge: how much is left of each resource

* force: 'player' in single-player games
* resource_name: 'coal', 'stone', etc
* site_name: "same as in the in-game resource monitor, e.g. S76"

### [ALS] factorio\_objects\_owned

gauge: how much items are in containers

* force: 'player' in single-player games
* item
* container

## Ethics

Some may view use of these metrics as cheating, insofar as they allow access to information
that isn't available in vanilla.  I expect how people feel will depend on the metric: information
on your own production and facilities probably isn't so bad, but information on enemy factions
is going to be more contentious.  It's easy to add and delete panels in Grafana, use only those
you're comfortable with.

## Thanks

Thanks to Tarantool for their [Lua Prometheus client library](https://github.com/tarantool/prometheus).

Thanks to Octav "Narc" Sandulescu for [YARM](https://github.com/narc0tiq/YARM).

Thanks to Amr Abed for [Advanced Logicistic System](https://github.com/anoutsider/advanced-logistics-system).
