#version 330 core
out vec4 fragColour;
uniform float time;
float pi = 3.14159265358979323846264338327950288419716939937510;

void main() {
    fragColour = vec4(sin(time) * 0.5 + 0.5, sin(time + 2 * pi / 3) * 0.5 + 0.5, sin(time + 4 * pi / 3) * 0.5 + 0.5, 1.0f);
}