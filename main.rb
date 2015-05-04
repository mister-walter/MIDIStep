require 'unimidi'
require 'midilib'
require 'midilib/io/seqreader'

class Bounds
	attr_accessor :min_pt
	attr_accessor :max_pt

	def initialize(min_pt, max_pt)
		@min_pt = min_pt
		@max_pt = max_pt
	end

	def outOfBound(pt)
		return ((pt < min_pt) || (pt > max_pt))
	end 
end

class BuildVolume
	attr_accessor :x
	attr_accessor :y
	attr_accessor :z

	def initialize(x,y,z)
		@x = x
		@y = y
		@z = z
	end

	def plan_movement(distance, current_posn, axis, settings)
		movements = []
		if(self.call(axis).outOfBound(current_posn + distance))
			posn = current_posn
			min_pt = self.call(axis).min_pt
			max_pt = self.call(axis).max_pt
			
			movements << max_pt - posn
			distance -= (max_pt - posn)
			posn = max_pt

			num_across = distance.div(max_pt - min_pt)
			num_across.times do |i|
				if posn == max_pt
					movements << min_pt
					distance -= (max_pt - min_pt)
				else
					movements << man_pt
					distance -= (max_pt - min_pt)
				end
			end
			
			if posn == max_pt
				movements << (max_pt - distance)
			else
				movements << (min_pt + distance)
			end

		else
			movements << distance
		end

		return movements
	end
end

class MidiNote
	attr_accessor :note
	attr_accessor :start_time
	attr_accessor :end_time

	def initialize(note, start_time, end_time)
		@note = note
		@start_time = start_time
		@end_time = end_time
	end

	def self.frequency(midi_note)
		return 2**((midi_note - 69) / 12.0) * 440
	end

	def frequency
		# From wikipedia (http://en.wikipedia.org/wiki/MIDI_Tuning_Standard)
		# freq = 2^[(note - 69)/12] * 440 Hz
		return 2**((note - 69) / 12.0) * 440
	end

	def duration
		return end_time - start_time
	end

	def print_speed(axis, settings)
		return self.frequency * 60.0 / settings.steps_per_mm.send(axis)
	end

	def self.print_speed(midi_note, axis, settings)
		return MidiNote.frequency(midi_note) * 60.0 / settings.steps_per_mm.send(axis)
	end

	def self.print_distance(duration, midi_note, axis, settings)
		return MidiNote.frequency(midi_note) / 60.0 * duration
	end

	def <=>(a_note)
		return start_time <=> a_note.start_time
	end
end

class StepsPerMM
	attr_accessor :x
	attr_accessor :y
	attr_accessor :z

	def initialize(x, y, z)
		@x = x
		@y = y
		@z = z
	end
end

class PrinterSettings
	attr_accessor :build_volume
	attr_accessor :safety_margin
	attr_accessor :steps_per_mm

	def initialize(build_volume, steps_per_mm, safety_margin = 20)
		@build_volume = build_volume
		@steps_per_mm = steps_per_mm
		@safety_margin = safety_margin
	end
end

def parse_midi(path)
	seq = MIDI::Sequence.new()
	File.open(path, 'rb') { |file|
		seq.read(file)
	}

	grouped_events = {}
	events = []
	seq.tracks.each do |track|
		events += track.events
	end

	events.sort_by! { |e| e.time_from_start }

	# tempo = 0
	events.each do |e|
	# 	if e.is_a? MIDI::Tempo
	# 		tempo = e
	# 	end
		puts e.inspect
		if (e.is_a? MIDI::NoteOn) || (e.is_a? MIDI::NoteOff)
			if grouped_events.has_key? e.time_from_start
				grouped_events[e.time_from_start] << e
			else
				grouped_events[e.time_from_start] = [e]
			end
		end
	end

	# active_notes = {}
	# parsed_notes = {}
	# events.each do |e|
	# 	if e.is_a? MIDI::NoteOn
	# 		unless active_notes.has_key? e.note
	# 			active_notes[e.note] = e.time_from_start
	# 		else
	# 			raise "Tried to turn on a note that was already on"
	# 		end
	# 	elsif e.is_a? MIDI::NoteOff
	# 		if active_notes.has_key? e.note
	# 			start_time = active_notes[e.note]
	# 			end_time = e.time_from_start
	# 			if parsed_notes.has_key? start_time
	# 				parsed_notes[start_time] << MidiNote.new(e.note, start_time, end_time)
	# 			else
	# 				parsed_notes[start_time] = [MidiNote.new(e.note, start_time, end_time)]
	# 			end
	# 			# Remove the note that just ended from active_notes
	# 			active_notes.delete e.note
	# 		else
	# 			raise "Tried to turn off a note that wasn't on"
	# 		end
	# 	end
	# end

	return grouped_events
end

def generate_gcode(midi_data, settings)
	gcode = []
	gcode << "G28\n" # home all axes
	gcode << "G1 Z10 F5000\n" #lift nozzle
	gcode << "G92 X-52 Y-30\n"
	gcode << "G0 X10 Y10\n"


	safety_margin = settings.safety_margin
	used = {x:false, y:false, z:false}
	current_posn = {x: settings.build_volume.x.min_pt + safety_margin,
					y: settings.build_volume.y.min_pt + safety_margin,
					z: settings.build_volume.z.max_pt + safety_margin}

	active_notes = {}

	#output = File.open(output_path, 'w')

	last_time = 0
	switch_dir = {x:1, y:1}
	puts "\n\n\n\n"

	midi_data.each_pair do |time, notes|
		puts "notes"
		puts "------------------------------------"
		puts notes.inspect
		puts "===================================="
		if last_time < time
			time_elapsed = time - last_time
			move_distance = {x:0, y:0}
			
			puts "\nactive notes"
			puts "------------------------------------"
			puts active_notes
			puts "===================================="
			active_notes.each do |active_note|
				#puts active_note.inspect
				#if (active_note.is_a? MIDI::NoteOn) or (active_note.is_a? MIDI::NoteOff)
					
					if active_notes.has_key? :x
						move_distance[:x] = MidiNote.print_distance(time_elapsed, active_notes[:x].note, :x, settings) * switch_dir[:x]

						if ((current_posn[:x] + move_distance[:x] > (settings.build_volume.x.max_pt - safety_margin)) and switch_dir[:x] == 1) or ((current_posn[:x] < (settings.build_volume.x.min_pt + safety_margin)) and switch_dir[:x] == -1)
							switch_dir[:x] = switch_dir[:x] * -1
						end

						current_posn[:x] += move_distance[:x]
					end

					if active_notes.has_key? :y
						move_distance[:y] = MidiNote.print_distance(time_elapsed, active_notes[:y].note, :y, settings) * switch_dir[:y]
						
						if ((current_posn[:y] > (settings.build_volume.y.max_pt - safety_margin)) and switch_dir[:y] == 1) or ((current_posn[:y] < (settings.build_volume.y.min_pt - safety_margin)) and switch_dir[:y] == -1)
							switch_dir[:y] = switch_dir[:y] * -1
						end

						current_posn[:y] += move_distance[:y]
					end
				#end
			end

			print_speeds = {}
			if(active_notes.has_key? :x)
				puts "speed for note #{active_notes[:x].note} is #{MidiNote.print_speed(active_notes[:x].note, :x, settings)}"
				print_speeds[:x] = MidiNote.print_speed(active_notes[:x].note, :x, settings)
			else
				print_speeds[:x] = 0
			end

			if(active_notes.has_key? :y)
				puts "speed for note #{active_notes[:y].note} is #{MidiNote.print_speed(active_notes[:y].note, :y, settings)}"
				print_speeds[:y] = MidiNote.print_speed(active_notes[:y].note, :y, settings)
			else
				print_speeds[:y] = 0
			end
			#print_speeds[:x] = active_notes.has_key? :x ? MidiNote.print_speed(active_notes[:x].note, :x, settings) : 0
			#rint_speeds[:y] = active_notes.has_key? :y ? MidiNote.print_speed(active_notes[:y].note, :y, settings) : 0

			combined_distance = Math.sqrt(move_distance[:x]**2 + move_distance[:y]**2)
			combined_speed = Math.sqrt(print_speeds[:x]**2 + print_speeds[:y]**2)

			if (move_distance[:x] != 0) and (move_distance[:y] != 0) 
				gcode << Kernel.sprintf("G1 X%.10f Y%.10f F%.10f\n", current_posn[:x], current_posn[:y], combined_speed)
			elsif move_distance[:x] != 0
				gcode << Kernel.sprintf("G1 X%.10f F%.10f\n", current_posn[:x], combined_speed)
			elsif move_distance[:y] != 0
				gcode << Kernel.sprintf("G1 Y%.10f F%.10f\n", current_posn[:y], combined_speed)
			else
				#G04 is dwell - basically pause
				gcode << Kernel.sprintf("G4 P%0.4f\n", time_elapsed * 10.0)
			end
		end
			#last_time = time
		#else
			notes.sort_by! { |note| note.note }
			notes.reverse.each do |note|
				if note.is_a? MIDI::NoteOn
					if active_notes.length < 2
						if active_notes.has_key? :x
							active_notes[:y] = note
						else
							active_notes[:x] = note
						end

					else
					end
				elsif note.is_a? MIDI::NoteOff
					if active_notes.any? { |key, active_note| note.note == active_note.note }
						puts "Turning off a note #{note.note}"
						active_notes.delete_if { |key, active_note| note.note == active_note.note }
					else
						raise "Tried to turn off a note that wasn't already playing"
					end
				end
			end
		#end
		last_time = time
	end

	return gcode
end

def write_gcode(gcode, output_path)
	f = File.open output_path, 'w'
	gcode.each do |line|
		f.write(line)
	end
	f.close
end

my_build_volume = BuildVolume.new(Bounds.new(0, 190),
								  Bounds.new(0, 190),
								  Bounds.new(0, 100))
my_steps_per_mm = StepsPerMM.new(160, 160, 8000)
my_printer_settings = PrinterSettings.new(my_build_volume, my_steps_per_mm, 10)

infile=ARGV[0]
outfile = ARGV[1]

midi = parse_midi(File.absolute_path(infile))
gcode = generate_gcode(midi, my_printer_settings)
write_gcode(gcode, File.absolute_path(outfile))