# frozen_string_literal: true

require "ffi"

module PSX
  # Minimal FFI wrapper over SDL2's queued-audio API. ruby-sdl2 (the gem we
  # use for video) doesn't expose audio, so we bind the half-dozen calls we
  # need directly. CDDA streams as 44.1 kHz signed-16-bit stereo PCM — same
  # format as the source audio sectors on a CD, no resampling required.
  module Audio
    extend FFI::Library
    ffi_lib ["SDL2", "/opt/homebrew/lib/libSDL2-2.0.0.dylib"]

    class AudioSpec < FFI::Struct
      layout :freq,     :int,
             :format,   :uint16,
             :channels, :uint8,
             :silence,  :uint8,
             :samples,  :uint16,
             :padding,  :uint16,
             :size,     :uint32,
             :callback, :pointer,
             :userdata, :pointer
    end

    AUDIO_S16LSB = 0x8010

    attach_function :SDL_OpenAudioDevice,
                    [:pointer, :int, :pointer, :pointer, :int], :uint32
    attach_function :SDL_QueueAudio,
                    [:uint32, :pointer, :uint32], :int
    attach_function :SDL_GetQueuedAudioSize,
                    [:uint32], :uint32
    attach_function :SDL_PauseAudioDevice,
                    [:uint32, :int], :void
    attach_function :SDL_ClearQueuedAudio,
                    [:uint32], :void
    attach_function :SDL_CloseAudioDevice,
                    [:uint32], :void

    # Open a stereo 16-bit playback device at the given sample rate. Returns
    # an opaque device-id, or nil if the open failed (no audio hardware,
    # SDL not built with audio, etc.). The caller should treat the absence
    # of a device as "run silent."
    def self.open_device(freq: 44_100, channels: 2, samples: 1024)
      desired = AudioSpec.new
      desired[:freq] = freq
      desired[:format] = AUDIO_S16LSB
      desired[:channels] = channels
      desired[:samples] = samples
      obtained = AudioSpec.new
      dev = SDL_OpenAudioDevice(nil, 0, desired, obtained, 0)
      return nil if dev == 0
      SDL_PauseAudioDevice(dev, 0)
      dev
    end

    # Queue raw PCM bytes (interleaved stereo S16LE) to the playback queue.
    # SDL drains it on its own thread; safe to call from any thread.
    def self.queue(device, bytes)
      return if device.nil?
      buf = FFI::MemoryPointer.new(:uint8, bytes.bytesize)
      buf.write_bytes(bytes)
      SDL_QueueAudio(device, buf, bytes.bytesize)
    end

    def self.queued_bytes(device)
      device ? SDL_GetQueuedAudioSize(device) : 0
    end

    def self.clear(device)
      SDL_ClearQueuedAudio(device) if device
    end

    def self.close(device)
      SDL_CloseAudioDevice(device) if device
    end
  end
end
