from PIL import Image, ImageDraw
import sys
import os

def mask_to_squircle(input_path, output_path):
    img = Image.open(input_path).convert("RGBA")
    
    # We will crop the center 800x800 first to guarantee no borders, then resize to 1024
    width, height = img.size
    left = (width - 800)/2
    top = (height - 800)/2
    right = (width + 800)/2
    bottom = (height + 800)/2
    img = img.crop((left, top, right, bottom))
    img = img.resize((1024, 1024), Image.Resampling.LANCZOS)
    
    # Create mask
    mask = Image.new("L", (1024, 1024), 0)
    draw = ImageDraw.Draw(mask)
    # Apple's corner radius is roughly 22.5% of the width. 1024 * 0.225 = 230
    draw.rounded_rectangle([(0, 0), (1024, 1024)], radius=230, fill=255)
    
    # Apply mask
    img.putalpha(mask)
    
    img.save(output_path, "PNG")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python mask_icon.py <input> <output>")
        sys.exit(1)
    mask_to_squircle(sys.argv[1], sys.argv[2])
