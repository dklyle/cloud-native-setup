#!/usr/bin/env Rscript
# Copyright (c) 2018-2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

# Show pod scaling data - memory use, boot time, CPU utilisation.

suppressMessages(suppressWarnings(library(ggplot2)))	# ability to plot nicely.
														# So we can plot multiple graphs
library(gridExtra)										# together.
suppressMessages(suppressWarnings(library(ggpubr))) # for ggtexttable.
suppressMessages(library(jsonlite))			# to load the data.
suppressMessages(library(scales))			# For de-science notation of axis
library(tibble)								# tibbles for tidy data

testnames=c(
	"k8s-rapid.*"
)

podbootdata=c()		# Track per-launch data
cpuidledata=c()		# Track cpu idle data per nodes
memfreedata=c()		# Track mem free data for nodes
inodefreedata=c()	# Track inode free data for nodes
ifpacketdata=c()	# Track interface packet data for nodes
ifoctetdata=c()		# Track interface octets data for nodes
ifdropdata=c()		# Track interface dropped data for nodes
iferrordata=c()		# Track interface errors data for nodes
memstats=c()		# Statistics for memory usage
cpustats=c()		# Statistics for cpu usage
bootstats=c()		# Statistics for boot (launch) times
inodestats=c()		# Statistics for inode usage

# values for scaling the secondary y axes on some graphs
mem_scale=1
cpu_scale=1
inode_scale=1
ip_scale=1
oct_scale=1
drop_scale=1
error_scale=1

# iterate over every set of results (test run)
for (currentdir in resultdirs) {
	# For every results file we are interested in evaluating
	for (testname in testnames) {
		matchdir=paste(inputdir, currentdir, sep="")
		matchfile=paste(testname, '\\.json', sep="")
		files=list.files(matchdir, pattern=matchfile)
		if ( length(files) == 0 ) {
			#warning(paste("Pattern [", matchdir, "/", matchfile, "] matched nothing"))
		}

		# For every matching results file
		for (ffound in files) {
			fname=paste(inputdir, currentdir, ffound, sep="")
			if ( !file.exists(fname)) {
				warning(paste("Skipping non-existent file: ", fname))
				next
			}
			# Derive the name from the test result dirname
			datasetname=basename(currentdir)

			# Import the data
			fdata=fromJSON(fname)

			# determine whether NoSchedule taint is present for each node
			# from the 'kubectl get nodes' data dump in the json
			node_sched_data=list()
			nodes=c()
			num_nodes=nrow(fdata$'kubectl-get-nodes'$items)
			for(n in seq(num_nodes)){
				json_node=fdata$'kubectl-get-nodes'$items[n,]
				json_node_name=json_node$metadata$name
				taints=data.frame(json_node$spec$taints)
				nosched = "false"
				if(nrow(taints) > 0) {
					for(t in seq(nrow(taints))){
						if(taints[t,]$effect == "NoSchedule") {
							nosched = "true"
							break
						}
					}
				}
				node_sched_data[json_node_name] = nosched
			}

			# De-nest the test name specific data
			shortname=substr(ffound, 1, nchar(ffound)-nchar(".json"))
			fdata=fdata[[shortname]]
			testname=datasetname

			# Most of the data we are looking for comes in BootResults, so pick it out to make
			# referencing easier
			br=fdata$BootResults

			########################################################
			#### Now extract all the pod launch boot data items ####
			########################################################
			local_bootdata=tibble(launch_time=br$launch_time$Result)
			local_bootdata=cbind(local_bootdata, n_pods=br$n_pods$Result)
			local_bootdata=cbind(local_bootdata, testname=rep(testname, length(local_bootdata$n_pods)))
			local_bootdata=cbind(local_bootdata, ns=br$date$ns)
			# get the epoch time in seconds for the boot
			local_bootdata$epoch = local_bootdata$ns/1000000000
			local_bootdata$s_offset = local_bootdata$epoch - local_bootdata[1,]$epoch

			# Now Calculate some stats. This gets more complicated as we may have n-nodes,
			# and we want to show a 'pod average', so we try to assess for all nodes. If
			# we have different 'size' nodes in a cluster, that could throw out the result,
			# but the only other option would be to try and show every node separately in the
			# table.

			# Get a list of all the nodes from the schedule data list
			nodes=names(node_sched_data)

			memtotal=0
			cputotal=0
			inodetotal=0
			cpu_idle_data=c()
			mem_free_data=c()
			inode_free_data=c()
			interface_packets_data=c()
			interface_octets_data=c()
			interface_dropped_data=c()
			interface_errors_data=c()
			# Calculate per-node totals, and tot them up to a global total.
			for (n in nodes) {
				# check if collectd node data has been untarred yet, if not untar
				node_dir=paste(inputdir, currentdir, n, sep="")
				if ( !file.exists(node_dir)) {
					node_tar=paste(inputdir, currentdir, n, ".tar.gz", sep="")
					system(paste("mkdir -p", node_dir))
					system(paste("tar -xzf", node_tar, "-C", node_dir))
				}
				# all collectd data is under localhost/
				localhost_dir=paste(node_dir, "localhost", sep="/")

				# grab memory data
				memory_dir=paste(localhost_dir, "memory", sep="/")	
				# filename has date on the end, so look for the right file name
				freemem_pattern='^memory\\-free'
				files=list.files(memory_dir, pattern=freemem_pattern)
				# collectd csv plugin starts a new file for each day of data collected
				for(file in files) {
					mem_free_csv=paste(memory_dir, file, sep="/")
					node_mem_free_data=read.csv(mem_free_csv, header=TRUE, sep=",")
					node_mem_free_data=cbind(node_mem_free_data,
											 node=rep(n, length(node_mem_free_data$value)))
					node_mem_free_data=cbind(node_mem_free_data,
											 testname=rep(testname, length(node_mem_free_data$value)))
					node_mem_free_data$s_offset = node_mem_free_data$epoch - local_bootdata[1,]$epoch

					mem_free_data=rbind(mem_free_data, node_mem_free_data)
				}

				# grab CPU data
				cpu_dir=paste(localhost_dir, "aggregation-cpu-average", sep="/")
				# filename has date on the end, so look for the right file name
				percent_idle_pattern='^percent\\-idle'
				files=list.files(cpu_dir, pattern=percent_idle_pattern)
				for(file in files) {
					cpu_idle_csv=paste(cpu_dir, file, sep="/")
					node_cpu_idle_data=read.csv(cpu_idle_csv, header=TRUE, sep=",")
					node_cpu_idle_data=cbind(node_cpu_idle_data,
											 node=rep(n, length(node_cpu_idle_data$value)))
					node_cpu_idle_data=cbind(node_cpu_idle_data,
											 testname=rep(testname, length(node_cpu_idle_data$value)))
					node_cpu_idle_data$s_offset = node_cpu_idle_data$epoch - local_bootdata[1,]$epoch

					cpu_idle_data=rbind(cpu_idle_data, node_cpu_idle_data)
				}

				# grab inode data
				inode_dir=paste(localhost_dir, "df-root", sep="/")
				# filename has date on the end, so look for the right file name
				inode_free_pattern='^df_inodes\\-free'
				files=list.files(inode_dir, pattern=inode_free_pattern)
				for(file in files) {
					inode_free_csv=paste(inode_dir, file, sep="/")
					node_inode_free_data=read.csv(inode_free_csv, header=TRUE, sep=",")
					node_inode_free_data=cbind(node_inode_free_data,
											   node=rep(n, length(node_inode_free_data$value)))
					node_inode_free_data=cbind(node_inode_free_data,
											   testname=rep(testname, length(node_inode_free_data$value)))
					node_inode_free_data$s_offset = node_inode_free_data$epoch - local_bootdata[1,]$epoch

					inode_free_data=rbind(inode_free_data, node_inode_free_data)
				}

				# grab interface data
				interface_dir_pattern='^interface\\-'
				files=list.files(localhost_dir, pattern=interface_dir_pattern)
				for (file in files) {
					interface_dir=paste(localhost_dir, file, sep="/")
					interface_name=substr(file, nchar("interface-")+1, nchar(file))

					# filename has date on the end, so look for the right file name
					interface_packets_pattern='^if_packets'
					int_files=list.files(interface_dir, pattern=interface_packets_pattern)
					for (int_file in int_files) {
						interface_packets_csv=paste(interface_dir, int_file, sep="/")
						node_interface_packets_data=read.csv(interface_packets_csv, header=TRUE, sep=",")
						node_interface_packets_data=cbind(node_interface_packets_data,
														  node=rep(n, length(node_interface_packets_data$epoch)))
						node_interface_packets_data=cbind(node_interface_packets_data,
														  testname=rep(testname,
																	   length(node_interface_packets_data$epoch)))
						node_interface_packets_data=cbind(node_interface_packets_data,
														  name=rep(interface_name,
																   length(node_interface_packets_data$epoch)))
						node_interface_packets_data$s_offset = node_interface_packets_data$epoch - local_bootdata[1,]$epoch

						interface_packets_data=rbind(interface_packets_data, node_interface_packets_data)
					}

					# filename has date on the end, so look for the right file name
					interface_octets_pattern='^if_octets'
					int_files=list.files(interface_dir, pattern=interface_octets_pattern)
					for (int_file in int_files) {
						interface_octets_csv=paste(interface_dir, int_file, sep="/")
						node_interface_octets_data=read.csv(interface_octets_csv, header=TRUE, sep=",")
						node_interface_octets_data=cbind(node_interface_octets_data,
														 node=rep(n, length(node_interface_octets_data$epoch)))
						node_interface_octets_data=cbind(node_interface_octets_data,
														 testname=rep(testname,
																	  length(node_interface_octets_data$epoch)))
						node_interface_octets_data=cbind(node_interface_octets_data,
														 name=rep(interface_name,
																  length(node_interface_octets_data$epoch)))
						node_interface_octets_data$s_offset = node_interface_octets_data$epoch - local_bootdata[1,]$epoch

						interface_octets_data=rbind(interface_octets_data, node_interface_octets_data)
					}

					# filename has date on the end, so look for the right file name
					interface_dropped_pattern='^if_dropped'
					int_files=list.files(interface_dir, pattern=interface_dropped_pattern)
					for (int_file in int_files) {
						interface_dropped_csv=paste(interface_dir, int_file, sep="/")
						node_interface_dropped_data=read.csv(interface_dropped_csv, header=TRUE, sep=",")
						node_interface_dropped_data=cbind(node_interface_dropped_data,
														  node=rep(n, length(node_interface_dropped_data$epoch)))
						node_interface_dropped_data=cbind(node_interface_dropped_data,
														  testname=rep(testname,
																	   length(node_interface_dropped_data$epoch)))
						node_interface_dropped_data=cbind(node_interface_dropped_data,
														  name=rep(interface_name,
																   length(node_interface_dropped_data$epoch)))
						node_interface_dropped_data$s_offset = node_interface_dropped_data$epoch - local_bootdata[1,]$epoch

						interface_dropped_data=rbind(interface_dropped_data, node_interface_dropped_data)
					}

					# filename has date on the end, so look for the right file name
					interface_errors_pattern='^if_errors'
					int_files=list.files(interface_dir, pattern=interface_errors_pattern)
					for (int_file in int_files) {
						interface_errors_csv=paste(interface_dir, int_file, sep="/")
						node_interface_errors_data=read.csv(interface_errors_csv, header=TRUE, sep=",")
						node_interface_errors_data=cbind(node_interface_errors_data,
														 node=rep(n, length(node_interface_errors_data$epoch)))
						node_interface_errors_data=cbind(node_interface_errors_data,
														 testname=rep(testname,
																	  length(node_interface_errors_data$epoch)))
						node_interface_errors_data=cbind(node_interface_errors_data,
														 name=rep(interface_name,
																  length(node_interface_errors_data$epoch)))
						node_interface_errors_data$s_offset = node_interface_errors_data$epoch - local_bootdata[1,]$epoch

						interface_errors_data=rbind(interface_errors_data, node_interface_errors_data)
					}
				}

				# Do not use the master (non-schedulable) nodes to calculate
				# launched pod metrics
				if(node_sched_data[n] == "true") {
					next
				}

				max_free_mem=max(node_mem_free_data$value)
				min_free_mem=min(node_mem_free_data$value)
				memtotal = memtotal + (max_free_mem - min_free_mem)
				max_idle_cpu=max(node_cpu_idle_data$value)
				min_idle_cpu=min(node_cpu_idle_data$value)
				cputotal = cputotal + (max_idle_cpu - min_idle_cpu)
				max_free_inode=max(node_inode_free_data$value)
				min_free_inode=min(node_inode_free_data$value)
				inodetotal = inodetotal + (max_free_inode - min_free_inode)
			}

			num_pods = local_bootdata$n_pods[length(local_bootdata$n_pods)]

			# calculate scaling for secondary y axis
			# the two y scales, in R, must be mathematically related
			mem_scale = max(c(mem_scale,
							  (max(mem_free_data$value) / (1024*1024*1024)) / num_pods))
			cpu_scale = max(c(cpu_scale,
							  max(cpu_idle_data$value) / num_pods))
			inode_scale = max(c(inode_scale,
								max(inode_free_data$value) / num_pods))
			ip_scale = max(c(ip_scale,
							 max(c(max(interface_packets_data$tx, na.rm=TRUE),
								   max(interface_packets_data$rx, na.rm=TRUE))) / num_pods))
			oct_scale = max(c(oct_scale,
							  max(c(max(interface_octets_data$tx, na.rm=TRUE),
									max(interface_octets_data$rx, na.rm=TRUE))) / num_pods))
			# drops and scale are often 0, so providing 1 so we won't scale by infinity
			drop_scale = max(c(drop_scale,
							   max(c(1,
									 max(interface_dropped_data$tx, na.rm=TRUE),
									 max(interface_dropped_data$rx, na.rm=TRUE))) / num_pods))
			error_scale = max(c(error_scale,
								max(c(1,
									  max(interface_errors_data$tx, na.rm=TRUE),
									  max(interface_errors_data$rx, na.rm=TRUE))) / num_pods))

			# We get data in b, but want the graphs in Gb.
			memtotal = memtotal / (1024*1024*1024)
			gb_per_pod = memtotal/num_pods
			pod_per_gb = 1/gb_per_pod

			# Memory usage stats.
			local_mems = c(
				"Test"=testname,
				"n"=num_pods,
				"Tot_Gb"=round(memtotal, 3),
				"avg_Gb"=round(gb_per_pod, 4),
				"n_per_Gb"=round(pod_per_gb, 2)
			)
			memstats=rbind(memstats, local_mems)

			# cpu usage stats
			local_cpus = c(
				"Test"=testname,
				"n"=num_pods,
				"Tot_CPU"=round(cputotal, 3),
				"avg_CPU"=round(cputotal/num_pods, 4)
			)
			cpustats=rbind(cpustats, local_cpus)

			# launch (boot) stats
			local_boots = c(
				"Test"=testname,
				"n"=num_pods,
				"median"=median(na.omit(local_bootdata)$launch_time)/1000,
				"min"=min(na.omit(local_bootdata)$launch_time)/1000,
				"max"=max(na.omit(local_bootdata)$launch_time)/1000,
				"sd"=round(sd(na.omit(local_bootdata)$launch_time)/1000, 4)
				)

			bootstats=rbind(bootstats, local_boots)

			# inode stats
			local_inodes = c(
				"Test"=testname,
				"n"=num_pods,
				"Tot_inode"=round(inodetotal, 3),
				"avg_inode"=round(inodetotal/num_pods, 4)
				)
			inodestats=rbind(inodestats, local_inodes)
		}

		# And collect up our rows into our global table of all results
		# These two tables *should* be the source of all the data we need to
		# process and plot (apart from the stats....)
		podbootdata=rbind(podbootdata, local_bootdata, make.row.names=FALSE)
		cpuidledata=rbind(cpuidledata, cpu_idle_data)
		memfreedata=rbind(memfreedata, mem_free_data)
		inodefreedata=rbind(inodefreedata, inode_free_data)
		ifpacketdata=rbind(ifpacketdata, interface_packets_data)
		ifoctetdata=rbind(ifoctetdata, interface_octets_data)
		ifdropdata=rbind(ifdropdata, interface_dropped_data)
		iferrordata=rbind(iferrordata, interface_errors_data)
	}
}

# It's nice to show the graphs in Gb, at least for any decent sized test
# run, so make a new column with that pre-divided data in it for us to use.
memfreedata$mem_free_gb = memfreedata$value/(1024*1024*1024)
# And show the boot times in seconds, not ms
podbootdata$launch_time_s = podbootdata$launch_time/1000.0

########### Output memory page ##############
mem_stats_plot = suppressWarnings(ggtexttable(data.frame(memstats),
	theme=ttheme(base_size=10),
	rows=NULL
	))

#mem_sec_axis_scale=
mem_line_plot <- ggplot() +
	geom_line(data=memfreedata,
			  aes(s_offset, mem_free_gb, colour=interaction(testname, node),
				  group=interaction(testname, node)),
			  alpha=0.3) +
	geom_point(data=memfreedata,
			   aes(s_offset, mem_free_gb, colour=interaction(testname, node),
				   group=interaction(testname, node)),
			   alpha=0.5, size=0.5) +
	geom_line(data=podbootdata,
			  aes(x=s_offset, y=n_pods*mem_scale, colour=interaction(testname,"pod count"), group=testname),
			  alpha=0.2) +
	geom_point(data=podbootdata,
			   aes(x=s_offset, y=n_pods*mem_scale, colour=interaction(testname,"pod count"), group=testname),
			   alpha=0.3, size=0.5) +
	labs(colour="") +
	xlab("seconds") +
	ylab("System Avail (Gb)") +
	scale_y_continuous(labels=comma, sec.axis=sec_axis(~ ./mem_scale, name="pods")) +
	ggtitle("System Memory free") +
	theme(axis.text.x=element_text(angle=90))

page1 = grid.arrange(
	mem_line_plot,
	mem_stats_plot,
	ncol=1
	)

# pagebreak, as the graphs overflow the page otherwise
cat("\n\n\\pagebreak\n")

########## Output cpu page ##############
cpu_stats_plot = suppressWarnings(ggtexttable(data.frame(cpustats),
	theme=ttheme(base_size=10),
	rows=NULL
	))

cpu_line_plot <- ggplot() +
	geom_line(data=cpuidledata,
			  aes(x=s_offset, y=value, colour=interaction(testname, node),
				  group=interaction(testname, node)),
			  alpha=0.3) +
	geom_point(data=cpuidledata,
			   aes(x=s_offset, y=value, colour=interaction(testname, node),
				   group=interaction(testname, node)),
			   alpha=0.5, size=0.5) +
	geom_line(data=podbootdata,
			  aes(x=s_offset, y=n_pods*cpu_scale, colour=interaction(testname,"pod count"), group=testname),
			  alpha=0.2) +
	geom_point(data=podbootdata,
			   aes(x=s_offset, y=n_pods*cpu_scale, colour=interaction(testname,"pod count"), group=testname),
			   alpha=0.3, size=0.5) +
	labs(colour="") +
	scale_y_continuous(labels=comma, sec.axis=sec_axis(~ ./cpu_scale, name="pods")) +
	xlab("seconds") +
	ylab("System CPU Idle (%)") +
	ggtitle("System CPU usage") +
	theme(axis.text.x=element_text(angle=90))

page2 = grid.arrange(
	cpu_line_plot,
	cpu_stats_plot,
	ncol=1
	)

# pagebreak, as the graphs overflow the page otherwise
cat("\n\n\\pagebreak\n")

########## Output boot page ##############
boot_stats_plot = suppressWarnings(ggtexttable(data.frame(bootstats),
	theme=ttheme(base_size=10),
	rows=NULL
	))

boot_line_plot <- ggplot() +
	geom_line(data=podbootdata,
			  aes(n_pods, launch_time_s, colour=testname, group=testname),
			  alpha=0.2) +
	xlab("pods") +
	ylab("Boot time (s)") +
	ggtitle("Pod boot time") +
	theme(axis.text.x=element_text(angle=90))

page3 = grid.arrange(
	boot_line_plot,
	boot_stats_plot,
	ncol=1
	)

# pagebreak, as the graphs overflow the page otherwise
cat("\n\n\\pagebreak\n")

########## Output inode page ##############
inode_stats_plot = suppressWarnings(ggtexttable(data.frame(inodestats),
	theme=ttheme(base_size=10),
	rows=NULL
	))

inode_line_plot <- ggplot() +
	geom_line(data=inodefreedata,
			  aes(x=s_offset, y=value, colour=interaction(testname, node),
				  group=interaction(testname, node)),
			  alpha=0.2) +
	geom_point(data=inodefreedata,
			   aes(x=s_offset, y=value, colour=interaction(testname, node),
				   group=interaction(testname, node)),
			   alpha=0.5, size=0.5) +
	geom_line(data=podbootdata,
			  aes(x=s_offset, y=n_pods*inode_scale, colour=interaction(testname,"pod count"), group=testname),
			  alpha=0.2) +
	geom_point(data=podbootdata,
			   aes(x=s_offset, y=n_pods*inode_scale, colour=interaction(testname,"pod count"), group=testname),
			   alpha=0.3, size=0.5) +
	labs(colour="") +
	xlab("seconds") +
	ylab("inodes free") +
	scale_y_continuous(labels=comma, sec.axis=sec_axis(~ ./inode_scale, name="pods")) +
	ggtitle("inodes free") +
	theme(axis.text.x=element_text(angle=90))

page4 = grid.arrange(
	inode_line_plot,
	inode_stats_plot,
	ncol=1
	)

# pagebreak, as the graphs overflow the page otherwise
cat("\n\n\\pagebreak\n")

########## Output interface page packets and octets ##############
interface_packet_line_plot <- ggplot() +
	geom_line(data=ifpacketdata,
			  aes(x=s_offset, y=tx, colour=interaction(testname, node, name, "tx"),
				  group=interaction(testname, node, name, "tx")),
			  alpha=0.2, na.rm=TRUE) +
	geom_point(data=ifpacketdata,
			   aes(x=s_offset, y=tx, colour=interaction(testname, node, name, "tx"),
				   group=interaction(testname, node, name, "tx")),
			   alpha=0.5, size=0.5, na.rm=TRUE) +
	geom_line(data=ifpacketdata,
			  aes(x=s_offset, y=rx, colour=interaction(testname, node, name, "rx"),
				  group=interaction(testname, node, name, "rx")),
			  alpha=0.2, na.rm=TRUE) +
	geom_point(data=ifpacketdata,
			   aes(x=s_offset, y=rx, colour=interaction(testname, node, name, "rx"),
				   group=interaction(testname, node, name, "rx")),
			   alpha=0.5, size=0.5, na.rm=TRUE) +
	geom_line(data=podbootdata,
			  aes(x=s_offset, y=n_pods*ip_scale, colour=interaction(testname,"pod count"), group=testname),
			  alpha=0.2) +
	geom_point(data=podbootdata,
			   aes(x=s_offset, y=n_pods*ip_scale, colour=interaction(testname,"pod count"), group=testname),
			   alpha=0.3, size=0.5) +
	labs(colour="") +
	xlab("seconds") +
	ylab("packets") +
	scale_y_continuous(labels=comma, sec.axis=sec_axis(~ ./ip_scale, name="pods")) +
	ggtitle("interface packets") +
	theme(axis.text.x=element_text(angle=90))

interface_octet_line_plot <- ggplot() +
	geom_line(data=ifoctetdata,
			  aes(x=s_offset, y=tx, colour=interaction(testname, node, name, "tx"),
				  group=interaction(testname, node, name, "tx")),
			  alpha=0.2, na.rm=TRUE) +
	geom_point(data=ifoctetdata,
			   aes(x=s_offset, y=tx, colour=interaction(testname, node, name, "tx"),
				   group=interaction(testname, node, name, "tx")),
			   alpha=0.5, size=0.5, na.rm=TRUE) +
	geom_line(data=ifoctetdata,
			  aes(x=s_offset, y=rx, colour=interaction(testname, node, name, "rx"),
				  group=interaction(testname, node, name, "rx")),
			  alpha=0.2, na.rm=TRUE) +
	geom_point(data=ifoctetdata,
			   aes(x=s_offset, y=rx, colour=interaction(testname, node, name, "rx"),
				   group=interaction(testname, node, name, "rx")),
			   alpha=0.5, size=0.5, na.rm=TRUE) +
	geom_line(data=podbootdata,
			  aes(x=s_offset, y=n_pods*oct_scale, colour=interaction(testname,"pod count"), group=testname),
			  alpha=0.2) +
	geom_point(data=podbootdata,
			   aes(x=s_offset, y=n_pods*oct_scale, colour=interaction(testname,"pod count"), group=testname),
			   alpha=0.3, size=0.5) +
	labs(colour="") +
	xlab("seconds") +
	ylab("octets") +
	scale_y_continuous(labels=comma, sec.axis=sec_axis(~ ./oct_scale, name="pods")) +
	ggtitle("interface octets") +
	theme(axis.text.x=element_text(angle=90))


page5 = grid.arrange(
	interface_packet_line_plot,
	interface_octet_line_plot,
	ncol=1
	)

# pagebreak, as the graphs overflow the page otherwise
cat("\n\n\\pagebreak\n")

########## Output interface page drops and errors ##############
interface_drop_line_plot <- ggplot() +
	geom_line(data=ifdropdata,
			  aes(x=s_offset, y=tx, colour=interaction(testname, node, name, "tx"),
				  group=interaction(testname, node, name, "tx")),
			  alpha=0.2, na.rm=TRUE) +
	geom_point(data=ifdropdata,
			   aes(x=s_offset, y=tx, colour=interaction(testname, node, name, "tx"),
				   group=interaction(testname, node, name, "tx")),
			   alpha=0.5, size=0.5, na.rm=TRUE) +
	geom_line(data=ifdropdata,
			  aes(x=s_offset, y=rx, colour=interaction(testname, node, name, "rx"),
				  group=interaction(testname, node, name, "rx")),
			  alpha=0.2, na.rm=TRUE) +
	geom_point(data=ifdropdata,
			   aes(x=s_offset, y=rx, colour=interaction(testname, node, name, "rx"),
				   group=interaction(testname, node, name, "rx")),
			   alpha=0.5, size=0.5, na.rm=TRUE) +
	geom_line(data=podbootdata,
			  aes(x=s_offset, y=n_pods*drop_scale, colour=interaction(testname,"pod count"), group=testname),
			  alpha=0.2) +
	geom_point(data=podbootdata,
			   aes(x=s_offset, y=n_pods*drop_scale, colour=interaction(testname,"pod count"), group=testname),
			   alpha=0.3, size=0.5) +
	labs(colour="") +
	xlab("seconds") +
	ylab("drops") +
	scale_y_continuous(labels=comma, sec.axis=sec_axis(~ ./drop_scale, name="pods")) +
	ggtitle("interface drops") +
	theme(axis.text.x=element_text(angle=90))

interface_error_line_plot <- ggplot() +
	geom_line(data=iferrordata,
			  aes(x=s_offset, y=tx, colour=interaction(testname, node, name, "tx"),
				  group=interaction(testname, node, name, name, "tx")),
			  alpha=0.2, na.rm=TRUE) +
	geom_point(data=iferrordata,
			   aes(x=s_offset, y=tx, colour=interaction(testname, node, name, "tx"),
				   group=interaction(testname, node, name, "tx")),
			   alpha=0.5, size=0.5, na.rm=TRUE) +
	geom_line(data=iferrordata,
			  aes(x=s_offset, y=rx, colour=interaction(testname, node, name, "rx"),
				  group=interaction(testname, node, name, "rx")),
			  alpha=0.2, na.rm=TRUE) +
	geom_point(data=iferrordata,
			   aes(x=s_offset, y=rx, colour=interaction(testname, node, name, "rx"),
				   group=interaction(testname, node, name, "rx")),
			   alpha=0.5, size=0.5, na.rm=TRUE) +
	geom_line(data=podbootdata,
			  aes(x=s_offset, y=n_pods*error_scale, colour=interaction(testname,"pod count"), group=testname),
			  alpha=0.2) +
	geom_point(data=podbootdata,
			   aes(x=s_offset, y=n_pods*error_scale, colour=interaction(testname,"pod count"), group=testname),
			   alpha=0.3, size=0.5) +
	labs(colour="") +
	xlab("seconds") +
	ylab("errors") +
	scale_y_continuous(labels=comma, sec.axis=sec_axis(~ ./error_scale, name="pods")) +
	ggtitle("interface errors") +
	theme(axis.text.x=element_text(angle=90))

page6 = grid.arrange(
	interface_drop_line_plot,
	interface_error_line_plot,
	ncol=1
	)
