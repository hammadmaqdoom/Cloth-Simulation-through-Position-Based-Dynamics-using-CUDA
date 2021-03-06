#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <time.h>

#include <GL/glew.h>
#include <GL/wglew.h>
#include <GL/freeglut.h>
#include <vector>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp> //for matrices
#include <glm/gtc/type_ptr.hpp>

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>

//undefine if u want to use the default bending constraint of pbd
#define USE_TRIANGLE_BENDING_CONSTRAINT

#pragma comment(lib, "glew32.lib")

using namespace std;
const int width = 1024, height = 1024;

#define PI 3.1415926536f
#define EPSILON  0.0000001f

int numX = 20, numY = 20; //these ar the number of quads
const size_t total_points = (numX + 1) * (numY + 1);
float fullsize = 4.0f;
float halfsize = fullsize / 2.0f;

char info[MAX_PATH] = { 0 };

float timeStep = 1.0f / 60.0f; //1.0/60.0f;
float currentTime = 0;
double accumulator = timeStep;
int selected_index = -1;
float global_dampening = 0.98f; //DevO: 24.07.2011  //global velocity dampening !!!

struct DistanceConstraint { int p1, p2;	float rest_length, k; float k_prime; };
#ifdef USE_TRIANGLE_BENDING_CONSTRAINT
struct BendingConstraint { int p1, p2, p3;	float rest_length, w, k; float k_prime; };
#else
struct BendingConstraint { int p1, p2, p3, p4;	float rest_length1, rest_length2, w1, w2, k; float k_prime; };
#endif

thrust::host_vector<GLushort> indices;
thrust::host_vector<DistanceConstraint> d_constraints;

thrust::device_vector<GLushort> dev_indices; // indices GPU


thrust::host_vector<BendingConstraint> b_constraints;
thrust::host_vector<float> phi0; //initial dihedral angle between adjacent triangles

//particle system
thrust::host_vector<glm::vec3> X; //position
thrust::host_vector<glm::vec3> tmp_X; //predicted position
thrust::host_vector<glm::vec3> V; //velocity
thrust::host_vector<glm::vec3> F;
thrust::host_vector<float> W; //inverse particle mass 
thrust::host_vector<glm::vec3> Ri; //Ri = Xi-Xcm 

//particle system GPU
thrust::device_vector<glm::vec3> *dev_X; //position GPU
thrust::device_vector<glm::vec3> *dev_tmp_X;
thrust::device_vector<glm::vec3> *dev_F; // force gpu
thrust::device_vector<float> *dev_W; //inverse particle mass GPU
thrust::device_vector<glm::vec3> *dev_V; //velocity gpu
int oldX = 0, oldY = 0;
float rX = 15, rY = 0;
int state = 1;
float dist = -23;
const int GRID_SIZE = 10;

const size_t solver_iterations = 2; //number of solver iterations per step. PBD  

float kBend = 0.5f;
float kStretch = 0.25f;
float kDamp = 0.00125f;
glm::vec3 gravity = glm::vec3(0.0f, -0.00981f, 0.0f);
glm::vec3 *dev_gravity;

float mass = 1.f / (total_points);


GLint viewport[4];
GLdouble MV[16];
GLdouble P[16];

LARGE_INTEGER frequency;        // ticks per second
LARGE_INTEGER t1, t2;           // ticks
double frameTimeQP = 0;
float frameTime = 0;


glm::vec3 Up = glm::vec3(0, 1, 0), Right, viewDir;
float startTime = 0, fps = 0;
int totalFrames = 0;

glm::mat4 ellipsoid, inverse_ellipsoid;
int iStacks = 30;
int iSlices = 30;
float fRadius = 1;

// Resolve constraint in object space
thrust::host_vector<glm::vec3> center = glm::vec3(0, 0, 0); //object space center of ellipsoid
thrust::device_vector<glm::vec3> *dev_center;
float radius = 1;					 //object space radius of ellipsoid
float *dev_radius;

////////////////////////////////////////////////////////////////////////////////
// constants
const unsigned int window_width = 1024;
const unsigned int window_height = 1024;

const unsigned int mesh_width = 256;
const unsigned int mesh_height = 256;

// vbo variables
GLuint vbo;
struct cudaGraphicsResource* cuda_vbo_resource;
void* d_vbo_buffer = NULL;

float g_fAnim = 0.0;

// mouse controls
int mouse_old_x, mouse_old_y;
int mouse_buttons = 0;
float rotate_x = 0.0, rotate_y = 0.0;
float translate_z = -3.0;

StopWatchInterface* timer = NULL;

// Auto-Verification Code
int fpsCount = 0;        // FPS count for averaging
int fpsLimit = 1;        // FPS limit for sampling
int g_Index = 0;
float avgFPS = 0.0f;
unsigned int frameCount = 0;
unsigned int g_TotalErrors = 0;
bool g_bQAReadback = false;

int* pArgc = NULL;
char** pArgv = NULL;

#define MAX(a,b) ((a > b) ? a : b)

////////////////////////////////////////////////////////////////////////////////
// declaration, forward
bool runTest(int argc, char** argv, char* ref_file);
void cleanup();

// GL functionality
bool initGL(int* argc, char** argv);
void createVBO(GLuint* vbo, struct cudaGraphicsResource** vbo_res,
	unsigned int vbo_res_flags);
void deleteVBO(GLuint* vbo, struct cudaGraphicsResource* vbo_res);

// rendering callbacks
void display();
void keyboard(unsigned char key, int x, int y);
void mouse(int button, int state, int x, int y);
void motion(int x, int y);
void timerEvent(int value);

// Cuda functionality
void runCuda(struct cudaGraphicsResource** vbo_resource);
void runAutoTest(int devID, char** argv, char* ref_file);
void checkResultCuda(int argc, char** argv, const GLuint& vbo);

const char* sSDKsample = "CUDA CLOTH (VBO)";



void StepPhysics(float dt);

float GetArea(int a, int b, int c) {
	glm::vec3 e1 = X[b] - X[a];
	glm::vec3 e2 = X[c] - X[a];
	return 0.5f * glm::length(glm::cross(e1, e2));
}
void AddDistanceConstraint(int a, int b, float k) {
	DistanceConstraint c;
	c.p1 = a;
	c.p2 = b;
	c.k = k;
	c.k_prime = 1.0f - pow((1.0f - c.k), 1.0f / solver_iterations);  //1.0f-pow((1.0f-c.k), 1.0f/ns);

	if (c.k_prime > 1.0)
		c.k_prime = 1.0;

	glm::vec3 deltaP = X[c.p1] - X[c.p2];
	c.rest_length = glm::length(deltaP);

	d_constraints.push_back(c);
}
#ifdef USE_TRIANGLE_BENDING_CONSTRAINT
void AddBendingConstraint(int pa, int pb, int pc, float k) {
	BendingConstraint c;
	c.p1 = pa;
	c.p2 = pb;
	c.p3 = pc;

	c.w = W[pa] + W[pb] + 2 * W[pc];
	glm::vec3 center = 0.3333f * (X[pa] + X[pb] + X[pc]);
	c.rest_length = glm::length(X[pc] - center);
	c.k = k;
	c.k_prime = 1.0f - pow((1.0f - c.k), 1.0f / solver_iterations);  //1.0f-pow((1.0f-c.k), 1.0f/ns);
	if (c.k_prime > 1.0)
		c.k_prime = 1.0;
	b_constraints.push_back(c);
}
#else
void AddBendingConstraint(int pa, int pb, int pc, int pd, float k) {
	BendingConstraint c;
	c.p1 = pa;
	c.p2 = pb;
	c.p3 = pc;
	c.p4 = pd;
	c.w1 = W[pa] + W[pb] + 2 * W[pc];
	c.w2 = W[pa] + W[pb] + 2 * W[pd];
	glm::vec3 center1 = 0.3333f * (X[pa] + X[pb] + X[pc]);
	glm::vec3 center2 = 0.3333f * (X[pa] + X[pb] + X[pd]);
	c.rest_length1 = glm::length(X[pc] - center1);
	c.rest_length2 = glm::length(X[pd] - center2);
	c.k = k;

	c.k_prime = 1.0f - pow((1.0f - c.k), 1.0f / solver_iterations);  //1.0f-pow((1.0f-c.k), 1.0f/ns);
	if (c.k_prime > 1.0)
		c.k_prime = 1.0;
	b_constraints.push_back(c);
}
#endif
void OnMouseDown(int button, int s, int x, int y)
{
	if (s == GLUT_DOWN)
	{
		oldX = x;
		oldY = y;
		int window_y = (height - y);
		float norm_y = float(window_y) / float(height / 2.0);
		int window_x = x;
		float norm_x = float(window_x) / float(width / 2.0);

		float winZ = 0;
		glReadPixels(x, height - y, 1, 1, GL_DEPTH_COMPONENT, GL_FLOAT, &winZ);
		if (winZ == 1)
			winZ = 0;
		double objX = 0, objY = 0, objZ = 0;
		gluUnProject(window_x, window_y, winZ, MV, P, viewport, &objX, &objY, &objZ);
		glm::vec3 pt(objX, objY, objZ);
		size_t i = 0;
		for (i = 0; i < total_points; i++) {
			if (glm::distance(X[i], pt) < 0.1) {
				selected_index = i;
				printf("Intersected at %d\n", i);
				break;
			}
		}
	}

	if (button == GLUT_MIDDLE_BUTTON)
		state = 0;
	else
		state = 1;

	if (s == GLUT_UP) {
		selected_index = -1;
		glutSetCursor(GLUT_CURSOR_INHERIT);
	}
}

void OnMouseMove(int x, int y)
{
	if (selected_index == -1) {
		if (state == 0)
			dist *= (1 + (y - oldY) / 60.0f);
		else
		{
			rY += (x - oldX) / 5.0f;
			rX += (y - oldY) / 5.0f;
		}
	}
	else {
		float delta = 1500 / abs(dist);
		float valX = (x - oldX) / delta;
		float valY = (oldY - y) / delta;
		if (abs(valX) > abs(valY))
			glutSetCursor(GLUT_CURSOR_LEFT_RIGHT);
		else
			glutSetCursor(GLUT_CURSOR_UP_DOWN);



		V[selected_index] = glm::vec3(0);
		//X[selected_index].x += Right[0]*valX ;
		//float newValue = X[selected_index].y+Up[1]*valY;
		//if(newValue>0)
		//	X[selected_index].y = newValue;
		//X[selected_index].z += Right[2]*valX + Up[2]*valY;
		X[selected_index].x += Right[0] * valX + Up[0] * valY;
		X[selected_index].y += Right[1] * valX + Up[1] * valY;
		X[selected_index].z += Right[2] * valX + Up[2] * valY;
	}
	oldX = x;
	oldY = y;

	glutPostRedisplay();
}

__global__ void DrawGridKernel()
{
	int i = threadId.x + blockId.x * blockDim.x;

	glVertex3f((float)i, 0, (float)-GRID_SIZE);
	glVertex3f((float)i, 0, (float)GRID_SIZE);

	glVertex3f((float)-GRID_SIZE, 0, (float)i);
	glVertex3f((float)GRID_SIZE, 0, (float)i);
}

void DrawGrid()
{
	glBegin(GL_LINES);
	glColor3f(0.5f, 0.5f, 0.5f);

	//draw grid
	dim3 blocks(GRID_SIZE / 16, GRID_SIZE / 16);
	dim3 threads(16, 16);
	DrawGridKernel<<<blocks, threads>>> ();

	glEnd();
}

inline glm::vec3 GetNormal(int ind0, int ind1, int ind2) {
	glm::vec3 e1 = X[ind0] - X[ind1];
	glm::vec3 e2 = X[ind2] - X[ind1];
	return glm::normalize(glm::cross(e1, e2));
}

#ifndef USE_TRIANGLE_BENDING_CONSTRAINT
inline float GetDihedralAngle(BendingConstraint c, float& d, glm::vec3& n1, glm::vec3& n2) {
	n1 = GetNormal(c.p1, c.p2, c.p3);
	n2 = GetNormal(c.p1, c.p2, c.p4);
	d = glm::dot(n1, n2);
	return acos(d);
}
#else
inline int getIndex(int i, int j) {
	return j * (numX + 1) + i;
}
#endif
void InitGL() {

	startTime = (float)glutGet(GLUT_ELAPSED_TIME);
	currentTime = startTime;

	// get ticks per second
	QueryPerformanceFrequency(&frequency);

	// start timer
	QueryPerformanceCounter(&t1);


	glEnable(GL_DEPTH_TEST);
	size_t i = 0, j = 0, count = 0;
	int l1 = 0, l2 = 0;
	float ypos = 7.0f;
	int v = numY + 1;
	int u = numX + 1;

	indices.resize(numX * numY * 2 * 3);

	X.resize(total_points);
	tmp_X.resize(total_points);
	V.resize(total_points);
	F.resize(total_points);
	Ri.resize(total_points);

	//fill in positions
	for (int j = 0; j <= numY; j++) {
		for (int i = 0; i <= numX; i++) {
			X[count++] = glm::vec3(((float(i) / (u - 1)) * 2 - 1) * halfsize, fullsize + 1, ((float(j) / (v - 1)) * fullsize));
		}
	}

	///DevO: 24.07.2011
	W.resize(total_points);
	for (i = 0; i < total_points; i++) {
		W[i] = 1.0f / mass;
	}
	/// 2 Fixed Points 
	W[0] = 0.0;
	W[numX] = 0.0;

	memcpy(&tmp_X[0].x, &X[0].x, sizeof(glm::vec3) * total_points);

	//fill in velocities	 
	memset(&(V[0].x), 0, total_points * sizeof(glm::vec3));

	//fill in indices
	GLushort* id = &indices[0];
	for (int i = 0; i < numY; i++) {
		for (int j = 0; j < numX; j++) {
			int i0 = i * (numX + 1) + j;
			int i1 = i0 + 1;
			int i2 = i0 + (numX + 1);
			int i3 = i2 + 1;
			if ((j + i) % 2) {
				*id++ = i0; *id++ = i2; *id++ = i1;
				*id++ = i1; *id++ = i2; *id++ = i3;
			}
			else {
				*id++ = i0; *id++ = i2; *id++ = i3;
				*id++ = i0; *id++ = i3; *id++ = i1;
			}
		}
	}

	glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
	//glPolygonMode(GL_BACK, GL_LINE);
	glPointSize(5);

	wglSwapIntervalEXT(0);

	//check the damping values
	if (kStretch > 1)
		kStretch = 1;
	if (kStretch < 0)
		kStretch = 0;
	if (kBend > 1)
		kBend = 1;
	if (kBend < 0)
		kBend = 0;
	if (kDamp > 1)
		kDamp = 1;
	if (kDamp < 0)
		kDamp = 0;
	if (global_dampening > 1)
		global_dampening = 1;

	//setup constraints
	// Horizontal
	for (l1 = 0; l1 < v; l1++)	// v
		for (l2 = 0; l2 < (u - 1); l2++) {
			AddDistanceConstraint((l1 * u) + l2, (l1 * u) + l2 + 1, kStretch);
		}

	// Vertical
	for (l1 = 0; l1 < (u); l1++)
		for (l2 = 0; l2 < (v - 1); l2++) {
			AddDistanceConstraint((l2 * u) + l1, ((l2 + 1) * u) + l1, kStretch);
		}


	// Shearing distance constraint
	for (l1 = 0; l1 < (v - 1); l1++)
		for (l2 = 0; l2 < (u - 1); l2++) {
			AddDistanceConstraint((l1 * u) + l2, ((l1 + 1) * u) + l2 + 1, kStretch);
			AddDistanceConstraint(((l1 + 1) * u) + l2, (l1 * u) + l2 + 1, kStretch);
		}


	// create bending constraints	
#ifdef USE_TRIANGLE_BENDING_CONSTRAINT
//add vertical constraints
	for (int i = 0; i <= numX; i++) {
		for (int j = 0; j < numY - 1; j++) {
			AddBendingConstraint(getIndex(i, j), getIndex(i, (j + 1)), getIndex(i, j + 2), kBend);
		}
	}
	//add horizontal constraints
	for (int i = 0; i < numX - 1; i++) {
		for (int j = 0; j <= numY; j++) {
			AddBendingConstraint(getIndex(i, j), getIndex(i + 1, j), getIndex(i + 2, j), kBend);
		}
	}

#else
	for (int i = 0; i < v - 1; ++i) {
		for (int j = 0; j < u - 1; ++j) {
			int p1 = i * (numX + 1) + j;
			int p2 = p1 + 1;
			int p3 = p1 + (numX + 1);
			int p4 = p3 + 1;

			if ((j + i) % 2) {
				AddBendingConstraint(p3, p2, p1, p4, kBend);
			}
			else {
				AddBendingConstraint(p4, p1, p3, p2, kBend);
			}
		}
	}
	float d;
	glm::vec3 n1, n2;
	phi0.resize(b_constraints.size());

	for (i = 0; i < b_constraints.size(); i++) {
		phi0[i] = GetDihedralAngle(b_constraints[i], d, n1, n2);
	}
#endif

	//create a basic ellipsoid object
	ellipsoid = glm::translate(glm::mat4(1), glm::vec3(0, 2, 0));
	ellipsoid = glm::rotate(ellipsoid, 45.0f, glm::vec3(1, 0, 0));
	ellipsoid = glm::scale(ellipsoid, glm::vec3(fRadius, fRadius, fRadius / 2));
	inverse_ellipsoid = glm::inverse(ellipsoid);
}

void OnReshape(int nw, int nh) {
	glViewport(0, 0, nw, nh);
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	gluPerspective(60, (GLfloat)nw / (GLfloat)nh, 1.f, 100.0f);

	glGetIntegerv(GL_VIEWPORT, viewport);
	glGetDoublev(GL_PROJECTION_MATRIX, P);

	glMatrixMode(GL_MODELVIEW);
}



void OnRender() {
	size_t i = 0;
	float newTime = (float)glutGet(GLUT_ELAPSED_TIME);
	frameTime = newTime - currentTime;
	currentTime = newTime;
	//accumulator += frameTime;

	//Using high res. counter
	QueryPerformanceCounter(&t2);
	// compute and print the elapsed time in millisec
	frameTimeQP = (t2.QuadPart - t1.QuadPart) * 1000.0 / frequency.QuadPart;
	t1 = t2;
	accumulator += frameTimeQP;

	++totalFrames;
	if ((newTime - startTime) > 1000)
	{
		float elapsedTime = (newTime - startTime);
		fps = (totalFrames / elapsedTime) * 1000;
		startTime = newTime;
		totalFrames = 0;
	}

	sprintf_s(info, "FPS: %3.2f, Frame time (GLUT): %3.4f msecs, Frame time (QP): %3.3f", fps, frameTime, frameTimeQP);
	glutSetWindowTitle(info);

	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glLoadIdentity();

	//set viewing transformation
	glTranslatef(0, 0, dist);
	glRotatef(rX, 1, 0, 0);
	glRotatef(rY, 0, 1, 0);

	glGetDoublev(GL_MODELVIEW_MATRIX, MV);
	viewDir.x = (float)-MV[2];
	viewDir.y = (float)-MV[6];
	viewDir.z = (float)-MV[10];
	//Right = glm::cross(viewDir, Up);
	Right.x = (float)MV[0];
	Right.y = (float)MV[4];
	Right.z = (float)MV[8];

	Up.x = (float)MV[1];
	Up.y = (float)MV[5];
	Up.z = (float)MV[9];

	DrawGrid();

	//draw ellipsoid
	glColor3f(0, 1, 0);
	glPushMatrix();
	glMultMatrixf(glm::value_ptr(ellipsoid));
	glutWireSphere(fRadius, iSlices, iStacks);
	glPopMatrix();


	//draw polygons
	glColor3f(1, 1, 1);
	glBegin(GL_TRIANGLES);
	for (i = 0; i < indices.size(); i += 3) {
		glm::vec3 p1 = X[indices[i]];
		glm::vec3 p2 = X[indices[i + 1]];
		glm::vec3 p3 = X[indices[i + 2]];
		glVertex3f(p1.x, p1.y, p1.z);
		glVertex3f(p2.x, p2.y, p2.z);
		glVertex3f(p3.x, p3.y, p3.z);
	}
	glEnd();

	//draw points

	glBegin(GL_POINTS);
	for (i = 0; i < total_points; i++) {
		glm::vec3 p = X[i];
		int is = (i == selected_index);
		glColor3f((float)!is, (float)is, (float)is);
		glVertex3f(p.x, p.y, p.z);
	}
	glEnd();


	//draw normals for debug only 	
#ifndef USE_TRIANGLE_BENDING_CONSTRAINT
#ifdef _DEBUG
	BendingConstraint b;
	float size = 0.1f;
	float d = 0;
	glm::vec3 n1, n2, c1, c2;


	glBegin(GL_LINES);
	for (i = 0; i < b_constraints.size(); i++) {
		b = b_constraints[i];
		c1 = (X[b.p1] + X[b.p2] + X[b.p3]) / 3.0f;
		c2 = (X[b.p1] + X[b.p2] + X[b.p4]) / 3.0f;
		GetDihedralAngle(b, d, n1, n2);
		glColor3f(abs(n1.x), abs(n1.y), abs(n1.z));
		glVertex3f(c1.x, c1.y, c1.z);		glVertex3f(c1.x + size * n1.x, c1.y + size * n1.y, c1.z + size * n1.z);

		glColor3f(abs(n2.x), abs(n2.y), abs(n2.z));
		glVertex3f(c2.x, c2.y, c2.z);		glVertex3f(c2.x + size * n2.x, c2.y + size * n2.y, c2.z + size * n2.z);
	}
	glEnd();
#endif
#endif
	glutSwapBuffers();
}

void OnShutdown() {
	d_constraints.clear();
	b_constraints.clear();
	indices.clear();
	X.clear();
	F.clear();
	V.clear();
	phi0.clear();
	W.clear();
	tmp_X.clear();
	Ri.clear();
}

void ComputeForces() 
{
  dim3 blocks(GRID_SIZE / 16, GRID_SIZE / 16);
  dim3 threads(16, 16);
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  cudaMalloc( (void**)&dev_F, F.size());
  cudaMalloc( (void**)&dev_W, W.size());
  cudaMalloc( (void**)&dev_gravity, gravity.size());

  cudaMemcpy(dev_F, F, F.size(), cudaMemcpyHostToDevice);
  cudaMemcpy(dev_W, W, W.size(), cudaMemcpyHostToDevice);
  cudaMemcpy(dev_gravity, gravity, gravity.size(), cudaMemcpyHostToDevice);

  cudaEventRecord(start);
  
  ComputeForcesKernel<<<blocks, threads>>> (dev_F, dev_W, dev_gravity);
  
  cudaEventRecord(stop);
  
  cudaDeviceSynchronize();
  
  cudaMemcpy(F, dev_F, F.size(), cudaMemcpyDeviceToHost);
  cudaMemcpy(W, dev_W, W.size(), cudaMemcpyDeviceToHost);
  cudaMemcpy(gravity, dev_gravity, gravity.size(), cudaMemcpyDeviceToHost);
  cudaEventSynchronize(stop);
  float dt3 = 0;
  cudaEventElapsedTime(&dt3, start, stop);
  printf("Total time on GPU for ComputeForces: %f msecs\n", dt3);


} 


_global_ void ComputeForcesKernel(thrust::device_vector<glm::vec3> *dev_F, thrust::device_vector<float> *dev_W, glm::vec3 *dev_gravity)
{
  int i = threadId.x + blockId.x * blockDim.x;
  dev_F[i] = glm::vec3(0); 
  //add gravity force
  if(dev_W[i]>0)
    dev_F[i] += dev_gravity;    
  __syncthreads(); 
 
}


void IntegrateExplicitWithDamping(float deltaTime) {
	float deltaTimeMass = deltaTime;
	size_t i = 0;

	glm::vec3 Xcm = glm::vec3(0);
	glm::vec3 Vcm = glm::vec3(0);
	float sumM = 0;
	for (i = 0; i < total_points; i++) {

		V[i] *= global_dampening; //global velocity dampening !!!		
		V[i] = V[i] + (F[i] * deltaTime) * W[i];

		//calculate the center of mass's position 
		//and velocity for damping calc
		Xcm += (X[i] * mass);
		Vcm += (V[i] * mass);
		sumM += mass;
	}
	Xcm /= sumM;
	Vcm /= sumM;

	glm::mat3 I = glm::mat3(1);
	glm::vec3 L = glm::vec3(0);
	glm::vec3 w = glm::vec3(0);//angular velocity


	for (i = 0; i < total_points; i++) {
		Ri[i] = (X[i] - Xcm);

		L += glm::cross(Ri[i], mass * V[i]);

		//thanks to DevO for pointing this and these notes really helped.
		//http://www.sccg.sk/~onderik/phd/ca2010/ca10_lesson11.pdf

		glm::mat3 tmp = glm::mat3(0, -Ri[i].z, Ri[i].y,
			Ri[i].z, 0, -Ri[i].x,
			-Ri[i].y, Ri[i].x, 0);
		I += (tmp * glm::transpose(tmp)) * mass;
	}

	w = glm::inverse(I) * L;

	//apply center of mass damping
	for (i = 0; i < total_points; i++) {
		glm::vec3 delVi = Vcm + glm::cross(w, Ri[i]) - V[i];
		V[i] += kDamp * delVi;
	}

	//calculate predicted position
	for (i = 0; i < total_points; i++) {
		if (W[i] <= 0.0) {
			tmp_X[i] = X[i]; //fixed points
		}
		else {
			tmp_X[i] = X[i] + (V[i] * deltaTime);
		}
	}
}

void Integrate(float deltaTime) 
{
  dim3 blocks(GRID_SIZE / 16, GRID_SIZE / 16);
  dim3 threads(16, 16);
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);
  cudaMalloc( (void**)&dev_X, X.size());
  cudaMalloc( (void**)&dev_V, V.size());
  cudaMalloc( (void**)&dev_tmp_X, tmp_X.size());
  cudaMemcpy(dev_X, X, X.size(), cudaMemcpyHostToDevice);
  cudaMemcpy(dev_V, V, V.size(), cudaMemcpyHostToDevice);
  cudaMemcpy(dev_tmp_X, tmp_X, tmp_X.size(), cudaMemcpyHostToDevice);
  cudaEventRecord(start);
  IntegrateKernel<<<blocks, threads>>> (deltaTime, dev_X, dev_V, dev_tmp_X);
  cudaEventRecord(stop);
  cudaDeviceSynchronize();
  cudaMemcpy(X, dev_X, X.size(), cudaMemcpyDeviceToHost);
  cudaMemcpy(V, dev_V, V.size(), cudaMemcpyDeviceToHost);
  cudaMemcpy(tmp_X, dev_tmp_X, tmp_X.size(), cudaMemcpyDeviceToHost);
  cudaEventSynchronize(stop);
  float dt4 = 0;
  cudaEventElapsedTime(&dt4, start, stop);
  printf("Total time on GPU for Integrate: %f msecs\n", dt4);
}

_global_ void IntegrateKernel(float deltaTime, thrust::device_vector<glm::vec3> *dev_X, thrust::device_vector<glm::vec3> *dev_V, thrust::device_vector<glm::vec3> *dev_tmp_X)
{
  float inv_dt = 1.0f / deltaTime;
  int i = threadId.x + blockId.x * blockDim.x;
  dev_V[i] = (dev_tmp_X[i] - dev_X[i]) * inv_dt;
  dev_X[i] = dev_tmp_X[i];
  __syncthreads(); 
 
}

void UpdateDistanceConstraint(int i) {

	DistanceConstraint c = d_constraints[i];
	glm::vec3 dir = tmp_X[c.p1] - tmp_X[c.p2];

	float len = glm::length(dir);
	if (len <= EPSILON)
		return;

	float w1 = W[c.p1];
	float w2 = W[c.p2];
	float invMass = w1 + w2;
	if (invMass <= EPSILON)
		return;

	glm::vec3 dP = (1.0f / invMass) * (len - c.rest_length) * (dir / len) * c.k_prime;
	if (w1 > 0.0)
		tmp_X[c.p1] -= dP * w1;

	if (w2 > 0.0)
		tmp_X[c.p2] += dP * w2;
}

void UpdateBendingConstraint(int index) {
	size_t i = 0;
	BendingConstraint c = b_constraints[index];

#ifdef USE_TRIANGLE_BENDING_CONSTRAINT
	//Using the paper suggested by DevO
	//http://image.diku.dk/kenny/download/kelager.niebe.ea10.pdf

	//global_k is a percentage of the global dampening constant 
	float global_k = global_dampening * 0.01f;
	glm::vec3 center = 0.3333f * (tmp_X[c.p1] + tmp_X[c.p2] + tmp_X[c.p3]);
	glm::vec3 dir_center = tmp_X[c.p3] - center;
	float dist_center = glm::length(dir_center);

	float diff = 1.0f - ((global_k + c.rest_length) / dist_center);
	glm::vec3 dir_force = dir_center * diff;
	glm::vec3 fa = c.k_prime * ((2.0f * W[c.p1]) / c.w) * dir_force;
	glm::vec3 fb = c.k_prime * ((2.0f * W[c.p2]) / c.w) * dir_force;
	glm::vec3 fc = -c.k_prime * ((4.0f * W[c.p3]) / c.w) * dir_force;

	if (W[c.p1] > 0.0) {
		tmp_X[c.p1] += fa;
	}
	if (W[c.p2] > 0.0) {
		tmp_X[c.p2] += fb;
	}
	if (W[c.p3] > 0.0) {
		tmp_X[c.p3] += fc;
	}
#else

	//Using the dihedral angle approach of the position based dynamics		
	float d = 0, phi = 0, i_d = 0;
	glm::vec3 n1 = glm::vec3(0), n2 = glm::vec3(0);

	glm::vec3 p1 = tmp_X[c.p1];
	glm::vec3 p2 = tmp_X[c.p2] - p1;
	glm::vec3 p3 = tmp_X[c.p3] - p1;
	glm::vec3 p4 = tmp_X[c.p4] - p1;

	glm::vec3 p2p3 = glm::cross(p2, p3);
	glm::vec3 p2p4 = glm::cross(p2, p4);

	float lenp2p3 = glm::length(p2p3);

	if (lenp2p3 == 0.0) { return; } //need to handle this case.

	float lenp2p4 = glm::length(p2p4);

	if (lenp2p4 == 0.0) { return; } //need to handle this case.

	n1 = glm::normalize(p2p3);
	n2 = glm::normalize(p2p4);

	d = glm::dot(n1, n2);
	phi = acos(d);

	//try to catch invalid values that will return NaN.
	// sqrt(1 - (1.0001*1.0001)) = NaN 
	// sqrt(1 - (-1.0001*-1.0001)) = NaN 
	if (d < -1.0)
		d = -1.0;
	else if (d > 1.0)
		d = 1.0; //d = clamp(d,-1.0,1.0);

	//in both case sqrt(1-d*d) will be zero and nothing will be done.
	//0?case, the triangles are facing in the opposite direction, folded together.
	if (d == -1.0) {
		phi = PI;  //acos(-1.0) == PI
		if (phi == phi0[index])
			return; //nothing to do 

	   //in this case one just need to push 
	   //vertices 1 and 2 in n1 and n2 directions, 
	   //so the constrain will do the work in second iterations.
		if (c.p1 != 0 && c.p1 != numX)
			tmp_X[c.p3] += n1 / 100.0f;

		if (c.p2 != 0 && c.p2 != numX)
			tmp_X[c.p4] += n2 / 100.0f;

		return;
	}
	if (d == 1.0) { //180?case, the triangles are planar
		phi = 0.0;  //acos(1.0) == 0.0
		if (phi == phi0[index])
			return; //nothing to do 
	}

	i_d = sqrt(1 - (d * d)) * (phi - phi0[index]);

	glm::vec3 p2n1 = glm::cross(p2, n1);
	glm::vec3 p2n2 = glm::cross(p2, n2);
	glm::vec3 p3n2 = glm::cross(p3, n2);
	glm::vec3 p4n1 = glm::cross(p4, n1);
	glm::vec3 n1p2 = -p2n1;
	glm::vec3 n2p2 = -p2n2;
	glm::vec3 n1p3 = glm::cross(n1, p3);
	glm::vec3 n2p4 = glm::cross(n2, p4);

	glm::vec3 q3 = (p2n2 + n1p2 * d) / lenp2p3;
	glm::vec3 q4 = (p2n1 + n2p2 * d) / lenp2p4;
	glm::vec3 q2 = (-(p3n2 + n1p3 * d) / lenp2p3) - ((p4n1 + n2p4 * d) / lenp2p4);

	glm::vec3 q1 = -q2 - q3 - q4;

	float q1_len2 = glm::dot(q1, q1);// glm::length(q1)*glm::length(q1);
	float q2_len2 = glm::dot(q2, q2);// glm::length(q2)*glm::length(q1);
	float q3_len2 = glm::dot(q3, q3);// glm::length(q3)*glm::length(q1);
	float q4_len2 = glm::dot(q4, q4);// glm::length(q4)*glm::length(q1); 

	float sum = W[c.p1] * (q1_len2)+
		W[c.p2] * (q2_len2)+
		W[c.p3] * (q3_len2)+
		W[c.p4] * (q4_len2);

	glm::vec3 dP1 = -((W[c.p1] * i_d) / sum) * q1;
	glm::vec3 dP2 = -((W[c.p2] * i_d) / sum) * q2;
	glm::vec3 dP3 = -((W[c.p3] * i_d) / sum) * q3;
	glm::vec3 dP4 = -((W[c.p4] * i_d) / sum) * q4;

	if (W[c.p1] > 0.0) {
		tmp_X[c.p1] += dP1 * c.k;
	}
	if (W[c.p2] > 0.0) {
		tmp_X[c.p2] += dP2 * c.k;
	}
	if (W[c.p3] > 0.0) {
		tmp_X[c.p3] += dP3 * c.k;
	}
	if (W[c.p4] > 0.0) {
		tmp_X[c.p4] += dP4 * c.k;
	}
#endif
}
//----------------------------------------------------------------------------------------------------
void GroundCollision() //DevO: 24.07.2011
{ 
  dim3 blocks(GRID_SIZE / 16, GRID_SIZE / 16);
  dim3 threads(16, 16);
  cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
  cudaMalloc( (void**)&dev_tmp_X, tmp_X.size());
  cudaMemcpy(dev_tmp_X, tmp_X, tmp_X.size(), cudaMemcpyHostToDevice);
  cudaEventRecord(start);
  GroundCollisionKernel<<<blocks, threads>>> (dev_tmp_X);
  cudaEventRecord(stop);
  cudaDeviceSynchronize();
  cudaMemcpy(tmp_X, dev_tmp_X, tmp_X.size(), cudaMemcpyDeviceToHost);
  cudaEventSynchronize(stop);
  float dt1 = 0;
	cudaEventElapsedTime(&dt1, start, stop);
  printf("Total time on GPU for GroundCollision: %f msecs\n", dt1);

}

_global_ void GroundCollisionKernel(thrust::device_vector<glm::vec3> *dev_tmp_X)
{
  
  int i = threadId.x + blockId.x * blockDim.x;
  if (dev_tmp_X[i].y < 0) //collision with ground
    Dev_tmp_X[i].y = 0;
  __syncthreads(); 
 
}

void EllipsoidCollision() 
{
  dim3 blocks(GRID_SIZE / 16, GRID_SIZE / 16);
  dim3 threads(16, 16);
  cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
  cudaMalloc( (void**)&dev_center, center.size());
  cudaMalloc( (void**)&dev_radius, radius.size());
  cudaMemcpy(dev_center, center, center.size(), cudaMemcpyHostToDevice);
  cudaMemcpy(dev_radius, radius, radius.size(), cudaMemcpyHostToDevice);
  cudaEventRecord(start);
  EllipsoidCollisionKernel<<<blocks, threads>>> (dev_center, dev_radius);
  cudaEventRecord(stop);
  cudaDeviceSynchronize();
  cudaMemcpy(center, dev_center, center.size(), cudaMemcpyDeviceToHost);
  cudaMemcpy(radius, dev_radius, radius.size(), cudaMemcpyDeviceToHost);
  cudaEventSynchronize(stop);
  float dt2 = 0;
	cudaEventElapsedTime(&dt2, start, stop);
  printf("Total time on GPU for EllipsoidCollision: %f msecs\n", dt2);
}


_global_ void EllipsoidCollisionKernel(thrust::device_vector<glm::vec3> *dev_center, float *dev_radius)
{
  int i = threadId.x + blockId.x * blockDim.x;
  glm::vec4 X_0 = (inverse_ellipsoid * glm::vec4(tmp_X[i], 1));
  glm::vec3 delta0 = glm::vec3(X_0.x, X_0.y, X_0.z) - dev_center;
  float distance = glm::length(delta0);
  if (distance < 1.0f) {
    delta0 = (dev_radius - distance) * delta0 / distance;
    // Transform the delta back to original space
    glm::vec3 delta;
    glm::vec3 transformInv;
    transformInv = glm::vec3(ellipsoid[0].x, ellipsoid[1].x, ellipsoid[2].x);
    transformInv /= glm::dot(transformInv, transformInv);
    delta.x = glm::dot(delta0, transformInv);
    transformInv = glm::vec3(ellipsoid[0].y, ellipsoid[1].y, ellipsoid[2].y);
    transformInv /= glm::dot(transformInv, transformInv);
    delta.y = glm::dot(delta0, transformInv);
    transformInv = glm::vec3(ellipsoid[0].z, ellipsoid[1].z, ellipsoid[2].z);
    transformInv /= glm::dot(transformInv, transformInv);
    delta.z = glm::dot(delta0, transformInv);
    tmp_X[i] += delta;
    V[i] = glm::vec3(0);
  __syncthreads(); 
 
}


void UpdateExternalConstraints() {
	// EllipsoidCollision();
}
//----------------------------------------------------------------------------------------------------
void UpdateInternalConstraints(float deltaTime) {
	size_t i = 0;

	//printf(" UpdateInternalConstraints \n ");
	for (size_t si = 0; si < solver_iterations; ++si) {
		for (i = 0; i < d_constraints.size(); i++) {
			UpdateDistanceConstraint(i);
		}
		for (i = 0; i < b_constraints.size(); i++) {
			UpdateBendingConstraint(i);
		}
		GroundCollision();
	}
}

void OnIdle() {

	/*
		//Semi-fixed time stepping
		if ( frameTime > 0.0 )
		{
			const float deltaTime = min( frameTime, timeStep );
			StepPhysics(deltaTime );
			frameTime -= deltaTime;
		}
		*/

		//printf(" ### OnIdle %f ### \n",accumulator);
		//Fixed time stepping + rendering at different fps	
	if (accumulator >= timeStep)
	{
		StepPhysics(timeStep);
		accumulator -= timeStep;
	}

	glutPostRedisplay();
	Sleep(5); //TODO
}

void StepPhysics(float dt) {

	ComputeForces();
	IntegrateExplicitWithDamping(dt);

	// for collision constraints
	UpdateInternalConstraints(dt);
	UpdateExternalConstraints();

	Integrate(dt);
}

void runCuda(struct cudaGraphicsResource** vbo_resource)
{
	// map OpenGL buffer object for writing from CUDA
	float4* dptr;
	checkCudaErrors(cudaGraphicsMapResources(1, vbo_resource, 0));
	size_t num_bytes;
	checkCudaErrors(cudaGraphicsResourceGetMappedPointer((void**)&dptr, &num_bytes,
		*vbo_resource));

	launch_kernel(dptr, mesh_width, mesh_height, g_fAnim);

	// unmap buffer object
	checkCudaErrors(cudaGraphicsUnmapResources(1, vbo_resource, 0));
}

void display()
{
	sdkStartTimer(&timer);

	// run CUDA kernel to generate 
	runCuda(&cuda_vbo_resource);

	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

	// set view matrix
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
	glTranslatef(0.0, 0.0, translate_z);
	glRotatef(rotate_x, 1.0, 0.0, 0.0);
	glRotatef(rotate_y, 0.0, 1.0, 0.0);

	// render from the vbo
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glVertexPointer(4, GL_FLOAT, 0, 0);

	glEnableClientState(GL_VERTEX_ARRAY);
	glColor3f(1.0, 0.0, 0.0);
	glDrawArrays(GL_POINTS, 0, mesh_width * mesh_height);
	glDisableClientState(GL_VERTEX_ARRAY);

	glutSwapBuffers();

	glutDisplayFunc(OnRender);
	glutReshapeFunc(OnReshape);
	glutIdleFunc(OnIdle);

	glutMouseFunc(OnMouseDown);
	glutMotionFunc(OnMouseMove);

	glutCloseFunc(OnShutdown);

	glewInit();
	InitGL();

	glutMainLoop();

	g_fAnim += 0.01f;

	sdkStopTimer(&timer);
	computeFPS();
}

void main(int argc, char** argv) {

	glutInit(&argc, argv);
	glutInitDisplayMode(GLUT_DOUBLE | GLUT_RGBA | GLUT_DEPTH);
	glutInitWindowSize(width, height);
	glutCreateWindow("CUDA Open Cloth Demo PBD");

	display()
}
