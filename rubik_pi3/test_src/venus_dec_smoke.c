// SPDX-License-Identifier: CC0-1.0
//
// venus_dec_smoke — gate 3.2 smoke test for the Qualcomm Venus decoder.
//
// Stateful V4L2 M2M decode of a canned Annex-B H.264 elementary stream:
//   1. QUERYCAP: expect an M2M mplane device
//   2. S_FMT OUTPUT=H264, queue access units split on slice NALs
//   3. wait for V4L2_EVENT_SOURCE_CHANGE, then set up CAPTURE (NV12)
//   4. count dequeued CAPTURE frames until EOS drain completes
//
// PASS = at least MIN_FRAMES frames decoded. Exit 0 on pass, 1 on fail.
//
// Build: make (cross-compiles with the system toolchain; see Makefile)
// Run:   venus_dec_smoke [/dev/video0] [stream.h264]

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define MIN_FRAMES 10
#define NUM_OUT_BUFS 4
#define NUM_CAP_BUFS 8
#define MAX_AUS 256

static int xioctl(int fd, unsigned long req, void *arg) {
  int r;
  do {
    r = ioctl(fd, req, arg);
  } while (r == -1 && errno == EINTR);
  return r;
}

struct au {
  const unsigned char *data;
  size_t len;
};

// Split an Annex-B stream into access units (one frame per buffer, as the
// stateful decoder API requires). An open AU (one that contains a slice)
// is closed when a NEW access unit begins: either a non-slice NAL
// (SPS/PPS/SEI/AUD) or a slice with first_mb_in_slice == 0 -- for ue(v),
// value 0 encodes as a single '1' bit, so the first RBSP payload bit is
// set. Multi-slice frames therefore stay in one buffer.
static int split_aus(const unsigned char *buf, size_t len, struct au *aus,
                     int max_aus) {
  int n = 0;
  size_t au_start = 0;
  int have_slice = 0;
  size_t i = 0;
  while (i + 3 < len) {
    size_t sc = 0;
    if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1)
      sc = 3;
    else if (i + 4 < len && buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 0 &&
             buf[i + 3] == 1)
      sc = 4;
    if (!sc) {
      i++;
      continue;
    }
    int nal_type = buf[i + sc] & 0x1f;
    int is_slice = (nal_type == 1 || nal_type == 5);
    int first_mb_zero =
        is_slice && (i + sc + 1 < len) && (buf[i + sc + 1] & 0x80);
    int starts_new_au = !is_slice || first_mb_zero;
    if (have_slice && starts_new_au && i > au_start) {
      if (n < max_aus) {
        aus[n].data = buf + au_start;
        aus[n].len = i - au_start;
        n++;
      }
      au_start = i;
      have_slice = 0;
    }
    if (is_slice)
      have_slice = 1;
    i += sc + 1;
  }
  if (au_start < len && n < max_aus) {
    aus[n].data = buf + au_start;
    aus[n].len = len - au_start;
    n++;
  } else if (au_start < len) {
    fprintf(stderr, "warn: stream truncated to %d access units (MAX_AUS)\n",
            max_aus);
  }
  return n;
}

// Find the venus DECODER node: enumeration order of /dev/video* is not
// stable across boots (the encoder has come up as video0), so scan for an
// M2M mplane device whose card name contains "decoder".
static int open_decoder(char *out, size_t outlen) {
  for (int i = 0; i < 8; i++) {
    char path[32];
    snprintf(path, sizeof(path), "/dev/video%d", i);
    int fd = open(path, O_RDWR | O_NONBLOCK);
    if (fd < 0)
      continue;
    struct v4l2_capability cap = {0};
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) == 0) {
      unsigned caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS)
                          ? cap.device_caps
                          : cap.capabilities;
      if ((caps & V4L2_CAP_VIDEO_M2M_MPLANE) &&
          strstr((const char *)cap.card, "decoder")) {
        snprintf(out, outlen, "%s", path);
        close(fd);
        return 0;
      }
    }
    close(fd);
  }
  return -1;
}

int main(int argc, char **argv) {
  char autodev[32];
  const char *dev;
  if (argc > 1) {
    dev = argv[1];
  } else {
    if (open_decoder(autodev, sizeof(autodev)) < 0) {
      fprintf(stderr, "FAIL: no M2M decoder found on /dev/video0-7\n");
      return 1;
    }
    dev = autodev;
  }
  const char *stream = argc > 2 ? argv[2] : "testsrc-320x240-30f.h264";

  // --- load the elementary stream ---
  FILE *f = fopen(stream, "rb");
  if (!f) {
    fprintf(stderr, "FAIL: cannot open stream %s: %s\n", stream,
            strerror(errno));
    return 1;
  }
  struct stat st;
  if (fstat(fileno(f), &st) < 0 || st.st_size <= 0) {
    fprintf(stderr, "FAIL: stat %s: %s\n", stream, strerror(errno));
    fclose(f);
    return 1;
  }
  unsigned char *es = malloc(st.st_size);
  if (!es) {
    fprintf(stderr, "FAIL: out of memory\n");
    fclose(f);
    return 1;
  }
  if (fread(es, 1, st.st_size, f) != (size_t)st.st_size) {
    fprintf(stderr, "FAIL: short read of %s\n", stream);
    free(es);
    fclose(f);
    return 1;
  }
  fclose(f);

  struct au aus[MAX_AUS];
  int n_aus = split_aus(es, st.st_size, aus, MAX_AUS);
  printf("stream: %s (%lld bytes, %d access units)\n", stream,
         (long long)st.st_size, n_aus);
  if (n_aus < MIN_FRAMES) {
    fprintf(stderr, "FAIL: test stream too short\n");
    return 1;
  }

  // --- open + querycap ---
  int fd = open(dev, O_RDWR | O_NONBLOCK);
  if (fd < 0) {
    fprintf(stderr, "FAIL: open %s: %s\n", dev, strerror(errno));
    return 1;
  }
  struct v4l2_capability cap = {0};
  if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
    fprintf(stderr, "FAIL: QUERYCAP: %s\n", strerror(errno));
    return 1;
  }
  unsigned caps =
      (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps
                                                : cap.capabilities;
  printf("device: %s driver=%s card=%s caps=0x%x\n", dev, cap.driver, cap.card,
         caps);
  if (!(caps & V4L2_CAP_VIDEO_M2M_MPLANE)) {
    fprintf(stderr, "FAIL: %s is not an M2M mplane device\n", dev);
    return 1;
  }

  // --- subscribe to source-change + EOS events ---
  struct v4l2_event_subscription sub = {0};
  sub.type = V4L2_EVENT_SOURCE_CHANGE;
  if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0)
    fprintf(stderr, "warn: subscribe SOURCE_CHANGE: %s\n", strerror(errno));
  sub.type = V4L2_EVENT_EOS;
  if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0)
    fprintf(stderr, "warn: subscribe EOS: %s\n", strerror(errno));

  // --- OUTPUT (bitstream) format + buffers ---
  struct v4l2_format ofmt = {0};
  ofmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
  ofmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_H264;
  ofmt.fmt.pix_mp.width = 320;
  ofmt.fmt.pix_mp.height = 240;
  ofmt.fmt.pix_mp.num_planes = 1;
  ofmt.fmt.pix_mp.plane_fmt[0].sizeimage = 1 << 20;
  if (xioctl(fd, VIDIOC_S_FMT, &ofmt) < 0) {
    fprintf(stderr, "FAIL: S_FMT(OUTPUT, H264): %s\n", strerror(errno));
    return 1;
  }

  struct v4l2_requestbuffers oreq = {0};
  oreq.count = NUM_OUT_BUFS;
  oreq.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
  oreq.memory = V4L2_MEMORY_MMAP;
  if (xioctl(fd, VIDIOC_REQBUFS, &oreq) < 0 || oreq.count == 0) {
    fprintf(stderr, "FAIL: REQBUFS(OUTPUT): %s\n", strerror(errno));
    return 1;
  }
  void *omap[NUM_OUT_BUFS];
  size_t olen[NUM_OUT_BUFS];
  for (unsigned i = 0; i < oreq.count; i++) {
    struct v4l2_buffer b = {0};
    struct v4l2_plane p[1] = {0};
    b.type = oreq.type;
    b.memory = V4L2_MEMORY_MMAP;
    b.index = i;
    b.length = 1;
    b.m.planes = p;
    if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
      fprintf(stderr, "FAIL: QUERYBUF(OUTPUT %u): %s\n", i, strerror(errno));
      return 1;
    }
    olen[i] = p[0].length;
    omap[i] = mmap(NULL, p[0].length, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                   p[0].m.mem_offset);
    if (omap[i] == MAP_FAILED) {
      fprintf(stderr, "FAIL: mmap(OUTPUT %u): %s\n", i, strerror(errno));
      return 1;
    }
  }
  int otype = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
  if (xioctl(fd, VIDIOC_STREAMON, &otype) < 0) {
    fprintf(stderr, "FAIL: STREAMON(OUTPUT): %s\n", strerror(errno));
    return 1;
  }

  // --- decode loop state ---
  int next_au = 0, queued_out = 0, cap_ready = 0, frames = 0, eos_sent = 0,
      done = 0;
  unsigned cap_count = 0;
  int pollerr_streak = 0;
  void *cmap[NUM_CAP_BUFS][2];
  unsigned cplanes = 1;
  int free_out[NUM_OUT_BUFS];
  for (int i = 0; i < NUM_OUT_BUFS; i++)
    free_out[i] = 1;

  for (int iter = 0; iter < 4000 && !done; iter++) {
    // queue bitstream AUs into any free OUTPUT buffers
    for (int i = 0; i < NUM_OUT_BUFS && next_au < n_aus; i++) {
      if (!free_out[i])
        continue;
      if (aus[next_au].len > olen[i]) {
        fprintf(stderr, "FAIL: AU %d larger than OUTPUT buffer\n", next_au);
        return 1;
      }
      memcpy(omap[i], aus[next_au].data, aus[next_au].len);
      struct v4l2_buffer b = {0};
      struct v4l2_plane p[1] = {0};
      b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
      b.memory = V4L2_MEMORY_MMAP;
      b.index = i;
      b.length = 1;
      b.m.planes = p;
      p[0].bytesused = aus[next_au].len;
      if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
        fprintf(stderr, "FAIL: QBUF(OUTPUT): %s\n", strerror(errno));
        return 1;
      }
      free_out[i] = 0;
      next_au++;
      queued_out++;
    }
    // all AUs queued: signal end of stream once
    if (next_au >= n_aus && !eos_sent) {
      struct v4l2_decoder_cmd cmd = {0};
      cmd.cmd = V4L2_DEC_CMD_STOP;
      if (xioctl(fd, VIDIOC_DECODER_CMD, &cmd) < 0)
        fprintf(stderr, "warn: DECODER_CMD STOP: %s\n", strerror(errno));
      eos_sent = 1;
    }

    struct pollfd pfd = {.fd = fd, .events = POLLIN | POLLOUT | POLLPRI};
    if (poll(&pfd, 1, 2000) <= 0) {
      fprintf(stderr, "FAIL: poll timeout (frames so far: %d)\n", frames);
      return 1;
    }
    if ((pfd.revents & POLLERR) &&
        !(pfd.revents & (POLLIN | POLLOUT | POLLPRI))) {
      // Both queues idle (POLLERR from the m2m core). Transient while the
      // capture side is not yet streaming; sustained means the decoder died.
      if (++pollerr_streak > 200) {
        fprintf(stderr, "FAIL: sustained POLLERR from decoder (frames: %d)\n",
                frames);
        return 1;
      }
      usleep(10 * 1000);
      continue;
    }
    pollerr_streak = 0;

    // events: source change → set up CAPTURE side
    if (pfd.revents & POLLPRI) {
      struct v4l2_event ev = {0};
      while (xioctl(fd, VIDIOC_DQEVENT, &ev) == 0) {
        if (ev.type == V4L2_EVENT_SOURCE_CHANGE && cap_ready) {
          fprintf(stderr,
                  "FAIL: mid-stream resolution change not supported by this "
                  "smoke test\n");
          return 1;
        } else if (ev.type == V4L2_EVENT_SOURCE_CHANGE && !cap_ready) {
          struct v4l2_format cfmt = {0};
          cfmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
          if (xioctl(fd, VIDIOC_G_FMT, &cfmt) < 0) {
            fprintf(stderr, "FAIL: G_FMT(CAPTURE): %s\n", strerror(errno));
            return 1;
          }
          printf("source change: %ux%u fourcc=%.4s planes=%u\n",
                 cfmt.fmt.pix_mp.width, cfmt.fmt.pix_mp.height,
                 (char *)&cfmt.fmt.pix_mp.pixelformat,
                 cfmt.fmt.pix_mp.num_planes);
          cplanes = cfmt.fmt.pix_mp.num_planes;
          if (cplanes < 1 || cplanes > 2) {
            fprintf(stderr, "FAIL: unsupported plane count %u\n", cplanes);
            return 1;
          }
          struct v4l2_requestbuffers creq = {0};
          creq.count = NUM_CAP_BUFS;
          creq.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
          creq.memory = V4L2_MEMORY_MMAP;
          if (xioctl(fd, VIDIOC_REQBUFS, &creq) < 0 || creq.count == 0) {
            fprintf(stderr, "FAIL: REQBUFS(CAPTURE): %s\n", strerror(errno));
            return 1;
          }
          cap_count = creq.count;
          for (unsigned i = 0; i < creq.count; i++) {
            struct v4l2_buffer b = {0};
            struct v4l2_plane p[2] = {0};
            b.type = creq.type;
            b.memory = V4L2_MEMORY_MMAP;
            b.index = i;
            b.length = cplanes;
            b.m.planes = p;
            if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
              fprintf(stderr, "FAIL: QUERYBUF(CAPTURE %u): %s\n", i,
                      strerror(errno));
              return 1;
            }
            for (unsigned j = 0; j < cplanes; j++) {
              cmap[i][j] = mmap(NULL, p[j].length, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, p[j].m.mem_offset);
              if (cmap[i][j] == MAP_FAILED) {
                fprintf(stderr, "FAIL: mmap(CAPTURE): %s\n", strerror(errno));
                return 1;
              }
            }
            if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
              fprintf(stderr, "FAIL: QBUF(CAPTURE %u): %s\n", i,
                      strerror(errno));
              return 1;
            }
          }
          int ctype = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
          if (xioctl(fd, VIDIOC_STREAMON, &ctype) < 0) {
            fprintf(stderr, "FAIL: STREAMON(CAPTURE): %s\n", strerror(errno));
            return 1;
          }
          cap_ready = 1;
        } else if (ev.type == V4L2_EVENT_EOS) {
          done = 1;
        }
      }
    }

    // reclaim finished OUTPUT buffers
    for (;;) {
      struct v4l2_buffer b = {0};
      struct v4l2_plane p[1] = {0};
      b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
      b.memory = V4L2_MEMORY_MMAP;
      b.length = 1;
      b.m.planes = p;
      if (xioctl(fd, VIDIOC_DQBUF, &b) < 0) {
        if (errno != EAGAIN && errno != EPIPE) {
          fprintf(stderr, "FAIL: DQBUF(OUTPUT): %s\n", strerror(errno));
          return 1;
        }
        break;
      }
      free_out[b.index] = 1;
    }

    // harvest decoded CAPTURE frames
    if (cap_ready) {
      for (;;) {
        struct v4l2_buffer b = {0};
        struct v4l2_plane p[2] = {0};
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        b.memory = V4L2_MEMORY_MMAP;
        b.length = cplanes;
        b.m.planes = p;
        if (xioctl(fd, VIDIOC_DQBUF, &b) < 0) {
          // EPIPE on CAPTURE = drained past the LAST buffer
          if (errno == EPIPE) {
            done = 1;
            break;
          }
          if (errno != EAGAIN) {
            fprintf(stderr, "FAIL: DQBUF(CAPTURE): %s\n", strerror(errno));
            return 1;
          }
          break;
        }
        int last = (b.flags & V4L2_BUF_FLAG_LAST) != 0;
        // B1: error-flagged buffers must not count as decoded frames
        if (p[0].bytesused > 0 && !(b.flags & V4L2_BUF_FLAG_ERROR))
          frames++;
        if (last) {
          done = 1;
          break;
        }
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
          fprintf(stderr, "FAIL: re-QBUF(CAPTURE): %s\n", strerror(errno));
          return 1;
        }
      }
    }
    if (frames >= MIN_FRAMES && eos_sent && done)
      break;
  }

  printf("decoded %d frames (%u capture buffers)\n", frames, cap_count);
  if (!done) {
    fprintf(stderr, "FAIL: drain did not complete (frames: %d)\n", frames);
    return 1;
  }
  if (frames >= MIN_FRAMES) {
    printf("PASS: venus decoded %d/%d frames\n", frames, n_aus);
    return 0;
  }
  fprintf(stderr, "FAIL: only %d frames decoded (need >= %d)\n", frames,
          MIN_FRAMES);
  return 1;
}
