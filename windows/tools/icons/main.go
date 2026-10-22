//go:build ignore

// Makes the icons of the tray and of the window: go run tools/icons/main.go (from windows/).
// The tray ring is the one of the Mac menu bar (StatusMenuController.icon): an oval of 17 by 6 in a field of 22 by 18; dashed and dim
// while nothing is on, solid while one or two services are on, thicker while all three are. The window icons are the two of the Mac Dock
// (art-studio/deliver/app-icon): idle and active.
package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"log"
	"math"
	"os"
	"path/filepath"
)

var traySizes = []int{16, 20, 24, 32, 48}
var windowSizes = []int{16, 20, 24, 32, 40, 48, 64, 256}

const out = "cmd/nimb/build/windows"

func main() {
	rings := []struct {
		name  string
		width float64 // in points of the Mac field
		dim   float64
		dash  bool
	}{
		{"none", 1.3, 0.5, true},
		{"some", 1.5, 1, false},
		{"all", 2.1, 1, false},
	}
	// Light is for the dark taskbar, dark for the light one.
	for _, theme := range []struct {
		name string
		rgb  uint8
	}{{"light", 255}, {"dark", 0}} {
		for _, r := range rings {
			var imgs []image.Image
			for _, s := range traySizes {
				imgs = append(imgs, ring(s, r.width, r.dim, r.dash, theme.rgb))
			}
			write(filepath.Join(out, "tray-"+r.name+"-"+theme.name+".ico"), imgs)
		}
	}
	for _, name := range []string{"idle", "active"} {
		f, err := os.Open("../art-studio/deliver/app-icon/icon-" + name + "-1024.png")
		if err != nil {
			log.Fatal(err)
		}
		src, err := png.Decode(f)
		f.Close()
		if err != nil {
			log.Fatal(err)
		}
		var imgs []image.Image
		for _, s := range windowSizes {
			imgs = append(imgs, shrink(src, s))
		}
		write(filepath.Join(out, "window-"+name+".ico"), imgs)
	}
}

// ring draws the oval of the Mac icon scaled so that it fills a square icon, anti-aliased by 16 by 16 samples per pixel.
func ring(size int, width, dim float64, dash bool, rgb uint8) image.Image {
	const field = 19.0 // the oval is 17 wide; a point of margin on each side
	k := float64(size) / field
	a, b := 8.5*k, 3.0*k // half axes
	w := width * k
	cx, cy := float64(size)/2, float64(size)/2
	// Length of the arc by the angle t of the parametrisation (x = a cos t, y = b sin t), for the dashes.
	const steps = 4096
	arc := make([]float64, steps+1)
	for i := 1; i <= steps; i++ {
		t := 2 * math.Pi * (float64(i) - 0.5) / steps
		arc[i] = arc[i-1] + math.Hypot(a*math.Sin(t), b*math.Cos(t))*2*math.Pi/steps
	}
	on, off := 2.2*k, 2.0*k
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	const n = 16
	for py := 0; py < size; py++ {
		for px := 0; px < size; px++ {
			hit := 0
			for sy := 0; sy < n; sy++ {
				for sx := 0; sx < n; sx++ {
					x := float64(px) + (float64(sx)+0.5)/n - cx
					y := float64(py) + (float64(sy)+0.5)/n - cy
					// Distance to the oval to the first order: f / |grad f|.
					f := x*x/(a*a) + y*y/(b*b) - 1
					g := math.Hypot(2*x/(a*a), 2*y/(b*b))
					if g == 0 || math.Abs(f/g) > w/2 {
						continue
					}
					if dash {
						t := math.Atan2(-y/b, x/a) // counter-clockwise from the right, as the Mac path
						if t < 0 {
							t += 2 * math.Pi
						}
						s := arc[int(t/(2*math.Pi)*steps)]
						if math.Mod(s, on+off) >= on {
							continue
						}
					}
					hit++
				}
			}
			if hit > 0 {
				alpha := float64(hit) / (n * n) * dim
				img.SetNRGBA(px, py, color.NRGBA{rgb, rgb, rgb, uint8(math.Round(alpha * 255))})
			}
		}
	}
	return img
}

// shrink scales an image down to a square of size by averaging (premultiplied, so that the transparent corners do not darken the edge).
func shrink(src image.Image, size int) image.Image {
	b := src.Bounds()
	step := float64(b.Dx()) / float64(size)
	dst := image.NewNRGBA(image.Rect(0, 0, size, size))
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			var r, g, bl, a, cnt float64
			for sy := int(float64(y) * step); sy < int(float64(y+1)*step); sy++ {
				for sx := int(float64(x) * step); sx < int(float64(x+1)*step); sx++ {
					cr, cg, cb, ca := src.At(b.Min.X+sx, b.Min.Y+sy).RGBA()
					r += float64(cr)
					g += float64(cg)
					bl += float64(cb)
					a += float64(ca)
					cnt++
				}
			}
			if a == 0 {
				continue
			}
			dst.SetNRGBA(x, y, color.NRGBA{uint8(r / a * 255), uint8(g / a * 255), uint8(bl / a * 255), uint8(a / cnt / 257)})
		}
	}
	return dst
}

// write packs PNG images into an icon file.
func write(path string, imgs []image.Image) {
	var data [][]byte
	for _, im := range imgs {
		var buf bytes.Buffer
		rgba := image.NewNRGBA(im.Bounds())
		draw.Draw(rgba, rgba.Bounds(), im, im.Bounds().Min, draw.Src)
		if err := png.Encode(&buf, rgba); err != nil {
			log.Fatal(err)
		}
		data = append(data, buf.Bytes())
	}
	var f bytes.Buffer
	binary.Write(&f, binary.LittleEndian, [3]uint16{0, 1, uint16(len(imgs))})
	offset := 6 + 16*len(imgs)
	for i, im := range imgs {
		s := im.Bounds().Dx()
		dim := byte(s)
		if s >= 256 {
			dim = 0
		}
		f.Write([]byte{dim, dim, 0, 0})
		binary.Write(&f, binary.LittleEndian, [2]uint16{1, 32})
		binary.Write(&f, binary.LittleEndian, [2]uint32{uint32(len(data[i])), uint32(offset)})
		offset += len(data[i])
	}
	for _, d := range data {
		f.Write(d)
	}
	if err := os.WriteFile(path, f.Bytes(), 0o644); err != nil {
		log.Fatal(err)
	}
	log.Println(path, f.Len())
}
